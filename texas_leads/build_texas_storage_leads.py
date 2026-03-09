#!/usr/bin/env python3
"""
Texas Self-Storage Lead CSV Pipeline.
Fetches from OpenStreetMap (Overpass), enriches, scores, and outputs
county-by-county CSVs plus master, missing-contact, and top-leads rollups.
"""

from __future__ import annotations

import csv
import re
import time
import urllib.request
import urllib.parse
import json
import os
from collections import defaultdict
from typing import Any

# Texas state bounding box (south, west, north, east)
TEXAS_BBOX = (25.84, -106.65, 36.5, -93.51)

# All 254 Texas counties (canonical names for file naming and assignment)
TEXAS_COUNTIES = [
    "Anderson", "Andrews", "Angelina", "Aransas", "Archer", "Armstrong", "Atascosa", "Austin",
    "Bailey", "Bandera", "Bastrop", "Baylor", "Bee", "Bell", "Bexar", "Blanco", "Borden", "Bosque",
    "Bowie", "Brazoria", "Brazos", "Brewster", "Briscoe", "Brooks", "Brown", "Burleson", "Burnet",
    "Caldwell", "Calhoun", "Callahan", "Cameron", "Camp", "Carson", "Cass", "Castro", "Chambers",
    "Cherokee", "Childress", "Clay", "Cochran", "Coke", "Coleman", "Collin", "Collingsworth",
    "Colorado", "Comal", "Comanche", "Concho", "Cooke", "Coryell", "Cottle", "Crane", "Crockett",
    "Crosby", "Culberson", "Dallam", "Dallas", "Dawson", "Deaf Smith", "Delta", "Denton", "DeWitt",
    "Dickens", "Dimmit", "Donley", "Duval", "Eastland", "Ector", "Edwards", "Ellis", "El Paso",
    "Erath", "Falls", "Fannin", "Fayette", "Fisher", "Floyd", "Foard", "Fort Bend", "Franklin",
    "Freestone", "Frio", "Gaines", "Galveston", "Garza", "Gillespie", "Glasscock", "Goliad",
    "Gonzales", "Gray", "Grayson", "Gregg", "Grimes", "Guadalupe", "Hale", "Hall", "Hamilton",
    "Hansford", "Hardeman", "Hardin", "Harris", "Harrison", "Hartley", "Haskell", "Hays",
    "Hemphill", "Henderson", "Hidalgo", "Hill", "Hockley", "Hood", "Hopkins", "Houston", "Howard",
    "Hudspeth", "Hunt", "Hutchinson", "Irion", "Jack", "Jackson", "Jasper", "Jeff Davis", "Jefferson",
    "Jim Hogg", "Jim Wells", "Johnson", "Jones", "Karnes", "Kaufman", "Kendall", "Kenedy", "Kent",
    "Kerr", "Kimble", "King", "Kinney", "Kleberg", "Knox", "Lamar", "Lamb", "Lampasas", "La Salle",
    "Lavaca", "Lee", "Leon", "Liberty", "Limestone", "Lipscomb", "Live Oak", "Llano", "Loving",
    "Lubbock", "Lynn", "Madison", "Marion", "Martin", "Mason", "Matagorda", "Maverick", "McCulloch",
    "McLennan", "McMullen", "Medina", "Menard", "Midland", "Milam", "Mills", "Mitchell", "Montague",
    "Montgomery", "Moore", "Morris", "Motley", "Nacogdoches", "Navarro", "Newton", "Nolan", "Nueces",
    "Ochiltree", "Oldham", "Orange", "Palo Pinto", "Panola", "Parker", "Parmer", "Pecos", "Polk",
    "Potter", "Presidio", "Rains", "Randall", "Reagan", "Real", "Red River", "Refugio", "Roberts",
    "Robertson", "Runnels", "Rusk", "Sabine", "San Augustine", "San Jacinto", "San Patricio",
    "San Saba", "Schleicher", "Scurry", "Shackelford", "Shelby", "Sherman", "Smith", "Somervell",
    "Starr", "Stephens", "Sterling", "Stonewall", "Sutton", "Swisher", "Tarrant", "Taylor", "Terrell",
    "Terry", "Throckmorton", "Titus", "Tom Green", "Travis", "Trinity", "Tyler", "Upshur", "Upton",
    "Uvalde", "Val Verde", "Van Zandt", "Victoria", "Walker", "Waller", "Ward", "Washington",
    "Webb", "Wharton", "Wheeler", "Wichita", "Wilbarger", "Willacy", "Williamson", "Wilson",
    "Winkler", "Wise", "Wood", "Yoakum", "Young", "Zapata", "Zavala",
]

KNOWN_CHAINS = {
    "public storage", "extra space", "extraspace", "cubesmart", "cube smart",
    "life storage", "u-haul", "uhaul", "storagemart", "storage mart",
    "istorage", "i storage", "uncle bobs", "uncle bob's", "safestore",
    "smartstop", "smart stop", "national storage", "americas self storage",
    "life storage", "simple self storage", "storage one", "a-1 self storage",
}

CSV_HEADER = [
    "Facility Name", "Ownership Group", "Ownership / Brand Name", "County", "Street Address",
    "City", "State", "ZIP Code", "Latitude", "Longitude", "Phone Number", "Email Address",
    "Website URL", "Estimated Unit Count", "Estimated Size / Footprint", "Facility Type Tags",
    "Lead Tier", "Lead Score", "Notes",
]


def normalize_phone(s: str | None) -> str:
    if not s:
        return ""
    digits = re.sub(r"\D", "", s)
    if len(digits) == 10:
        return f"{digits[:3]}-{digits[3:6]}-{digits[6:]}"
    if len(digits) == 11 and digits[0] == "1":
        return f"{digits[1:4]}-{digits[4:7]}-{digits[7:]}"
    return s.strip()


def normalize_for_dedupe(s: str | None) -> str:
    if not s:
        return ""
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", (s or "").lower())).strip()


def get_tag(e: dict, *keys: str) -> str:
    tags = e.get("tags") or {}
    for k in keys:
        if k in tags and tags[k]:
            return (tags[k] or "").strip()
    return ""


def get_lat_lon(e: dict) -> tuple[str, str]:
    lat = e.get("lat") or (e.get("center") or {}).get("lat")
    lon = e.get("lon") or (e.get("center") or {}).get("lon")
    return (str(lat) if lat is not None else "", str(lon) if lon is not None else "")


def classify_ownership(name: str, brand: str) -> tuple[str, str]:
    """Returns (Ownership Group, Ownership / Brand Name)."""
    combined = f"{name} {brand}".lower()
    for chain in KNOWN_CHAINS:
        if chain in combined:
            return ("Chain", brand.strip() or name.strip() or "Independent")
    if name or brand:
        return ("Independent", brand.strip() or name.strip() or "Independent")
    return ("", "")


def compute_lead_score(row: dict) -> int:
    score = 0
    if (row.get("Ownership Group") or "").strip() == "Independent":
        score += 25
    if (row.get("Phone Number") or "").strip():
        score += 15
    if (row.get("Website URL") or "").strip():
        score += 15
    if (row.get("Email Address") or "").strip():
        score += 10
    if (row.get("Estimated Unit Count") or "").strip():
        try:
            n = int((row.get("Estimated Unit Count") or "").replace(",", ""))
            if 0 < n <= 500:
                score += 10
        except ValueError:
            pass
    if (row.get("Ownership Group") or "").strip() == "Chain":
        score -= 25
    if not (row.get("Phone Number") or "").strip() and not (row.get("Website URL") or "").strip():
        score -= 10
    return max(0, min(100, score))


def lead_tier(score: int) -> str:
    if score >= 75:
        return "A"
    if score >= 50:
        return "B"
    return "C"


def fetch_overpass() -> list[dict]:
    south, west, north, east = TEXAS_BBOX
    # Maximize coverage: tagged storage + name-based match (self storage, mini storage, etc.)
    name_regex = "self.?storage|mini.?storage|storage.?unit|rv.?storage|boat.?storage|storage.?facilit|u.?haul.?storage"
    query = f"""
[out:json][timeout:180];
(
  node["shop"="storage_rental"]({south},{west},{north},{east});
  way["shop"="storage_rental"]({south},{west},{north},{east});
  relation["shop"="storage_rental"]({south},{west},{north},{east});
  node["amenity"="storage_rental"]({south},{west},{north},{east});
  way["amenity"="storage_rental"]({south},{west},{north},{east});
  relation["amenity"="storage_rental"]({south},{west},{north},{east});
  node["name"~"{name_regex}",i]({south},{west},{north},{east});
  way["name"~"{name_regex}",i]({south},{west},{north},{east});
);
out center meta;
"""
    urls = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"]
    elements = []
    for url in urls:
        try:
            req = urllib.request.Request(url, data=query.encode("utf-8"), method="POST")
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            req.add_header("User-Agent", "TexasStorageLeads/1.0")
            with urllib.request.urlopen(req, timeout=200) as resp:
                data = json.loads(resp.read().decode())
            elements = data.get("elements") or []
            break
        except Exception:
            continue
    # Dedupe by OSM (type, id) so same object from multiple query branches appears once
    seen = set()
    out = []
    for e in elements:
        key = (e.get("type"), e.get("id"))
        if key not in seen:
            seen.add(key)
            out.append(e)
    # Second pass: broader name match (name contains "storage") to catch untagged facilities
    broad_query = f"""
[out:json][timeout:180];
(
  node["name"~"storage",i]({south},{west},{north},{east});
  way["name"~"storage",i]({south},{west},{north},{east});
);
out center meta;
"""
    for url in urls:
        try:
            req = urllib.request.Request(url, data=broad_query.encode("utf-8"), method="POST")
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            req.add_header("User-Agent", "TexasStorageLeads/1.0")
            with urllib.request.urlopen(req, timeout=200) as resp:
                data = json.loads(resp.read().decode())
            for e in data.get("elements") or []:
                key = (e.get("type"), e.get("id"))
                if key in seen:
                    continue
                name = (e.get("tags") or {}).get("name") or ""
                # Exclude IT and industrial/utility – keep only storage-facility type
                skip = any(x in name.lower() for x in (
                    "cloud storage", "data storage", "software", "database", "server farm",
                    "sql ", " backup ", "san ", "nas ", "network attached",
                    "energy storage", "storage tank", "fuel storage", "water storage",
                    " oil storage", "gas storage", "chemical storage", "tank farm"
                ))
                if skip:
                    continue
                seen.add(key)
                out.append(e)
            break
        except Exception:
            continue
    # Third pass: locker, moving+storage, pack+store, etc. (maximize toward 5k)
    extra_regex = "locker|moving.?storage|storage.?moving|pack.?store|pack.?and.?store"
    extra_query = f"""
[out:json][timeout:180];
(
  node["name"~"{extra_regex}",i]({south},{west},{north},{east});
  way["name"~"{extra_regex}",i]({south},{west},{north},{east});
);
out center meta;
"""
    for url in urls:
        try:
            req = urllib.request.Request(url, data=extra_query.encode("utf-8"), method="POST")
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            req.add_header("User-Agent", "TexasStorageLeads/1.0")
            with urllib.request.urlopen(req, timeout=200) as resp:
                data = json.loads(resp.read().decode())
            for e in data.get("elements") or []:
                key = (e.get("type"), e.get("id"))
                if key not in seen:
                    seen.add(key)
                    out.append(e)
            break
        except Exception:
            continue
    return out


def assign_county(lat: str, lon: str, county_geoms: list[tuple[str, Any]] | None) -> str:
    if not lat or not lon or not county_geoms:
        return ""
    try:
        from shapely.geometry import shape, Point
        pt = Point(float(lon), float(lat))
        for name, geom in county_geoms:
            if geom.contains(pt):
                return name
    except Exception:
        pass
    return ""


def load_texas_counties_geojson() -> list[tuple[str, Any]] | None:
    """Load Texas counties from Census GeoJSON (STATE=48). Returns list of (county_name, shapely geom)."""
    try:
        from shapely.geometry import shape
        url = "https://raw.githubusercontent.com/plotly/datasets/master/geojson-counties-fips.json"
        with urllib.request.urlopen(url, timeout=30) as resp:
            fc = json.loads(resp.read().decode())
        out = []
        for f in (fc.get("features") or []):
            props = f.get("properties") or {}
            if props.get("STATE") != "48":
                continue
            name = (props.get("NAME") or "").strip()
            if not name:
                continue
            try:
                geom = shape(f.get("geometry"))
                out.append((name, geom))
            except Exception:
                continue
        return out if out else None
    except Exception:
        return None


def osm_to_rows(elements: list[dict], county_geoms: list[tuple[str, Any]] | None) -> list[dict]:
    rows = []
    for e in elements:
        tags = e.get("tags") or {}
        name = get_tag(e, "name", "brand")
        if not name and not get_tag(e, "brand"):
            name = "Self Storage"
        lat, lon = get_lat_lon(e)
        addr_street = get_tag(e, "addr:street", "street", "address")
        addr_city = get_tag(e, "addr:city", "city")
        addr_state = get_tag(e, "addr:state", "state") or "TX"
        addr_postcode = get_tag(e, "addr:postcode", "postcode", "zip")
        phone = normalize_phone(get_tag(e, "phone", "contact:phone", "phone:number"))
        email = get_tag(e, "contact:email", "email", "addr:email")
        website = get_tag(e, "website", "contact:website", "url")
        brand = get_tag(e, "brand", "operator")
        county = assign_county(lat, lon, county_geoms)
        og, brand_name = classify_ownership(name, brand)
        facility_types = get_tag(e, "self_service", "capacity", "amenity")
        type_tags = []
        if "climate" in (tags.get("description") or "").lower() or "climate" in (tags.get("climate") or "").lower():
            type_tags.append("climate-controlled")
        if "drive" in (tags.get("description") or "").lower():
            type_tags.append("drive-up")
        if "rv" in (tags.get("description") or "").lower() or "boat" in (tags.get("description") or "").lower():
            type_tags.append("RV/boat")
        if not type_tags:
            type_tags.append("self-storage")
        type_tags_str = ",".join(type_tags) if type_tags else ""
        unit_count = get_tag(e, "capacity:units", "units", "unit_count") or ""
        size_sqft = get_tag(e, "capacity", "area", "sqft") or ""
        notes = []
        if not website and not phone:
            notes.append("No website found")
        if email and "contact form" in (tags.get("contact") or "").lower():
            notes.append("Contact form only")
        if og == "Chain":
            notes.append("Chain-managed")
        row = {
            "Facility Name": name or "",
            "Ownership Group": og,
            "Ownership / Brand Name": brand_name or "",
            "County": county,
            "Street Address": addr_street,
            "City": addr_city,
            "State": addr_state,
            "ZIP Code": addr_postcode,
            "Latitude": lat,
            "Longitude": lon,
            "Phone Number": phone,
            "Email Address": email,
            "Website URL": website,
            "Estimated Unit Count": unit_count,
            "Estimated Size / Footprint": size_sqft,
            "Facility Type Tags": type_tags_str,
            "Lead Tier": "",
            "Lead Score": "",
            "Notes": "; ".join(notes) if notes else "",
        }
        score = compute_lead_score(row)
        row["Lead Score"] = score
        row["Lead Tier"] = lead_tier(score)
        rows.append(row)
    return rows


def dedupe(rows: list[dict]) -> list[dict]:
    seen = set()
    out = []
    for r in rows:
        key = (
            normalize_for_dedupe(r.get("Facility Name")),
            normalize_for_dedupe(r.get("Street Address")),
            normalize_for_dedupe(r.get("Phone Number")),
        )
        if key in seen:
            continue
        seen.add(key)
        out.append(r)
    return out


def safe_filename(county: str) -> str:
    return re.sub(r"[^\w\s-]", "", county).strip().replace(" ", "_")


def write_csv(path: str, rows: list[dict]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=CSV_HEADER, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def main() -> None:
    out_dir = os.path.join(os.path.dirname(__file__), "output")
    os.makedirs(out_dir, exist_ok=True)

    county_geoms = load_texas_counties_geojson()

    elements = fetch_overpass()
    rows = osm_to_rows(elements, county_geoms)
    rows = dedupe(rows)

    by_county = defaultdict(list)
    for r in rows:
        co = (r.get("County") or "").strip()
        if co:
            by_county[co].append(r)
        else:
            by_county["Unknown"].append(r)

    for county_name in TEXAS_COUNTIES:
        county_rows = by_county.get(county_name, [])
        fname = f"texas_{safe_filename(county_name)}_storage_facilities.csv"
        write_csv(os.path.join(out_dir, fname), county_rows)

    all_rows = sorted(rows, key=lambda r: (r.get("County") or "", r.get("Facility Name") or ""))
    write_csv(os.path.join(out_dir, "texas_all_counties_master.csv"), all_rows)

    missing = [
        r for r in rows
        if (not (r.get("Phone Number") or "").strip() and not (r.get("Website URL") or "").strip())
        or not (r.get("Email Address") or "").strip()
    ]
    write_csv(os.path.join(out_dir, "texas_missing_contact_followup.csv"), missing)

    top = [r for r in rows if (r.get("Lead Tier") or "") == "A"]
    top.sort(key=lambda r: -(r.get("Lead Score") or 0))
    write_csv(os.path.join(out_dir, "texas_top_leads_sfc.csv"), top)


if __name__ == "__main__":
    main()
