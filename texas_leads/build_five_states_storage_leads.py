#!/usr/bin/env python3
"""
Self-Storage Lead CSV Pipeline for Oklahoma, Arkansas, Kansas, New Mexico, Louisiana.
Same logic as Texas pipeline: Overpass (3 passes), county assignment, scoring, dedupe.
Output: one folder per state with county CSVs + master, missing_contact, top_leads.
"""

from __future__ import annotations

import csv
import re
import urllib.request
import json
import os
from collections import defaultdict
from typing import Any

# State FIPS: OK=40, AR=05, KS=20, NM=35, LA=22
# Bbox (south, west, north, east) for each state
STATE_CONFIG = {
    "oklahoma": {"fips": "40", "abbr": "OK", "bbox": (33.62, -103.0, 37.0, -94.43)},
    "arkansas": {"fips": "05", "abbr": "AR", "bbox": (33.0, -94.62, 36.5, -89.64)},
    "kansas": {"fips": "20", "abbr": "KS", "bbox": (36.99, -102.05, 40.0, -94.59)},
    "new_mexico": {"fips": "35", "abbr": "NM", "bbox": (31.33, -109.05, 37.0, -103.0)},
    "louisiana": {"fips": "22", "abbr": "LA", "bbox": (28.93, -94.04, 33.02, -88.82)},
}

KNOWN_CHAINS = {
    "public storage", "extra space", "extraspace", "cubesmart", "cube smart",
    "life storage", "u-haul", "uhaul", "storagemart", "storage mart",
    "istorage", "i storage", "uncle bobs", "uncle bob's", "safestore",
    "smartstop", "smart stop", "national storage", "americas self storage",
    "simple self storage", "storage one", "a-1 self storage",
}

CSV_HEADER = [
    "Facility Name", "Ownership Group", "Ownership / Brand Name", "County", "Street Address",
    "City", "State", "ZIP Code", "Latitude", "Longitude", "Phone Number", "Email Address",
    "Website URL", "Estimated Unit Count", "Estimated Size / Footprint", "Facility Type Tags",
    "Lead Tier", "Lead Score", "Notes",
]

BLACKLIST = (
    "cloud storage", "data storage", "software", "database", "server farm",
    "sql ", " backup ", "san ", "nas ", "network attached",
    "energy storage", "storage tank", "fuel storage", "water storage",
    " oil storage", "gas storage", "chemical storage", "tank farm"
)


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


def fetch_overpass(bbox: tuple[float, float, float, float]) -> list[dict]:
    south, west, north, east = bbox
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
    seen = set()
    out = []
    for e in elements:
        key = (e.get("type"), e.get("id"))
        if key not in seen:
            seen.add(key)
            out.append(e)
    broad_query = f"""
[out:json][timeout:180];
( node["name"~"storage",i]({south},{west},{north},{east}); way["name"~"storage",i]({south},{west},{north},{east}); );
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
                if any(x in name.lower() for x in BLACKLIST):
                    continue
                seen.add(key)
                out.append(e)
            break
        except Exception:
            continue
    extra_regex = "locker|moving.?storage|storage.?moving|pack.?store|pack.?and.?store"
    extra_query = f"""
[out:json][timeout:180];
( node["name"~"{extra_regex}",i]({south},{west},{north},{east}); way["name"~"{extra_regex}",i]({south},{west},{north},{east}); );
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
        from shapely.geometry import Point
        pt = Point(float(lon), float(lat))
        for name, geom in county_geoms:
            if geom.contains(pt):
                return name
    except Exception:
        pass
    return ""


def load_census_geojson() -> dict | None:
    try:
        url = "https://raw.githubusercontent.com/plotly/datasets/master/geojson-counties-fips.json"
        with urllib.request.urlopen(url, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def get_state_counties_and_geoms(fc: dict, fips: str) -> tuple[list[str], list[tuple[str, Any]]]:
    from shapely.geometry import shape
    names = []
    geoms = []
    for f in (fc.get("features") or []):
        props = f.get("properties") or {}
        if props.get("STATE") != fips:
            continue
        name = (props.get("NAME") or "").strip()
        if not name:
            continue
        try:
            geom = shape(f.get("geometry"))
            names.append(name)
            geoms.append((name, geom))
        except Exception:
            continue
    return (names, geoms)


def osm_to_rows(elements: list[dict], county_geoms: list[tuple[str, Any]] | None, state_abbr: str) -> list[dict]:
    rows = []
    for e in elements:
        tags = e.get("tags") or {}
        name = get_tag(e, "name", "brand")
        if not name and not get_tag(e, "brand"):
            name = "Self Storage"
        lat, lon = get_lat_lon(e)
        addr_street = get_tag(e, "addr:street", "street", "address")
        addr_city = get_tag(e, "addr:city", "city")
        addr_state = get_tag(e, "addr:state", "state") or state_abbr
        addr_postcode = get_tag(e, "addr:postcode", "postcode", "zip")
        phone = normalize_phone(get_tag(e, "phone", "contact:phone", "phone:number"))
        email = get_tag(e, "contact:email", "email", "addr:email")
        website = get_tag(e, "website", "contact:website", "url")
        brand = get_tag(e, "brand", "operator")
        county = assign_county(lat, lon, county_geoms)
        og, brand_name = classify_ownership(name, brand)
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
            "State": state_abbr,
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


def safe_filename(s: str) -> str:
    return re.sub(r"[^\w\s-]", "", s).strip().replace(" ", "_")


def write_csv(path: str, rows: list[dict]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=CSV_HEADER, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def main() -> None:
    base_dir = os.path.join(os.path.dirname(__file__), "output")
    fc = load_census_geojson()
    if not fc:
        print("Failed to load Census GeoJSON")
        return
    for state_slug, config in STATE_CONFIG.items():
        fips = config["fips"]
        abbr = config["abbr"]
        bbox = config["bbox"]
        out_dir = os.path.join(base_dir, state_slug)
        os.makedirs(out_dir, exist_ok=True)
        county_names, county_geoms = get_state_counties_and_geoms(fc, fips)
        print(f"Fetching {state_slug} ({abbr})...")
        elements = fetch_overpass(bbox)
        rows = osm_to_rows(elements, county_geoms, abbr)
        rows = dedupe(rows)
        print(f"  {len(rows)} facilities")
        by_county = defaultdict(list)
        for r in rows:
            co = (r.get("County") or "").strip()
            if co:
                by_county[co].append(r)
        for cname in county_names:
            county_rows = by_county.get(cname, [])
            fname = f"{state_slug}_{safe_filename(cname)}_storage_facilities.csv"
            write_csv(os.path.join(out_dir, fname), county_rows)
        all_rows = sorted(rows, key=lambda r: (r.get("County") or "", r.get("Facility Name") or ""))
        write_csv(os.path.join(out_dir, f"{state_slug}_all_counties_master.csv"), all_rows)
        missing = [
            r for r in rows
            if (not (r.get("Phone Number") or "").strip() and not (r.get("Website URL") or "").strip())
            or not (r.get("Email Address") or "").strip()
        ]
        write_csv(os.path.join(out_dir, f"{state_slug}_missing_contact_followup.csv"), missing)
        top = [r for r in rows if (r.get("Lead Tier") or "") == "A"]
        top.sort(key=lambda r: -(r.get("Lead Score") or 0))
        write_csv(os.path.join(out_dir, f"{state_slug}_top_leads_sfc.csv"), top)
    print("Done.")


if __name__ == "__main__":
    main()
