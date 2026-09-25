List<Object> _alphanumericPartsForSort(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return <Object>[''];
  final out = <Object>[];
  for (final m in RegExp(r'\d+|\D+').allMatches(s)) {
    final g = m.group(0)!;
    final n = int.tryParse(g);
    out.add(n ?? g.toLowerCase());
  }
  return out;
}

/// Puts "2" before "10" for typical storage unit labels: letters compare as
/// text and each run of digits as a number, so C2-2 < C2-10 < C10-1 and
/// A5 < B3.
int compareUnitNumbersNatural(String a, String b) {
  final pa = _alphanumericPartsForSort(a);
  final pb = _alphanumericPartsForSort(b);
  final n = pa.length < pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final va = pa[i];
    final vb = pb[i];
    if (va is int && vb is int) {
      final c = va.compareTo(vb);
      if (c != 0) return c;
    } else {
      final c = va.toString().compareTo(vb.toString());
      if (c != 0) return c;
    }
  }
  return pa.length.compareTo(pb.length);
}
