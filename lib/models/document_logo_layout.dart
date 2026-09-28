/// Where the facility logo sits in the letterhead of printed documents.
enum DocumentLogoPosition {
  /// Beside the business name and address (the original statement layout).
  left,

  /// On its own line above the business name and address.
  above,

  /// Centered across the top of the page, above everything else.
  center;

  static DocumentLogoPosition? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final p in values) {
      if (p.name == raw) return p;
    }
    return null;
  }
}

/// How the owner wants their logo laid out on every printed document: the
/// account statement PDF, the invoice PDF, and the HTML invoice and payment
/// receipt. Stored on the facility doc as `documentLogo`.
///
/// Sizes are in PDF points (1/72 inch). The HTML documents use the same
/// numbers as CSS `pt`, so a logo prints the same physical size whichever
/// document it is on.
class DocumentLogoLayout {
  const DocumentLogoLayout({
    this.height = defaultHeight,
    this.position = DocumentLogoPosition.left,
    this.showName = true,
  });

  static const double minHeight = 40;
  static const double maxHeight = 160;

  /// The statement letterhead's logo height before this was adjustable.
  static const double defaultHeight = 64;

  static const DocumentLogoLayout defaults = DocumentLogoLayout();

  /// Logo height in points. Width follows the logo's own proportions, up to
  /// [maxWidth].
  final double height;
  final DocumentLogoPosition position;

  /// Whether the business name is printed as text next to the logo. Many
  /// logos already spell the name out. The name is always printed when there
  /// is no logo to print (see [nameVisible]).
  final bool showName;

  /// The widest the logo may get, so a very wide logo cannot push the
  /// business details or the document title off the page. Beside the details
  /// it has to leave them room; above them or centered it can use more of the
  /// page's 468pt content width.
  double get maxWidth => switch (position) {
        DocumentLogoPosition.left => 180,
        DocumentLogoPosition.above => 260,
        DocumentLogoPosition.center => 400,
      };

  /// Whether the business name prints as text. Hiding it only applies when a
  /// logo actually prints; otherwise the document would carry no name at all.
  bool nameVisible({required bool logoShown}) => showName || !logoShown;

  /// Reads the stored map. Anything missing or malformed falls back to the
  /// default for that setting, and the height is kept within the slider's
  /// range, so a bad value on the doc can never break a statement.
  factory DocumentLogoLayout.fromMap(Object? raw) {
    if (raw is! Map) return defaults;
    final rawHeight = raw['height'];
    final height = rawHeight is num && rawHeight.isFinite
        ? rawHeight.toDouble().clamp(minHeight, maxHeight).toDouble()
        : defaultHeight;
    final showName = raw['showName'];
    return DocumentLogoLayout(
      height: height,
      position: DocumentLogoPosition.tryParse(raw['position']) ??
          DocumentLogoPosition.left,
      showName: showName is bool ? showName : true,
    );
  }

  Map<String, dynamic> toMap() => {
        'height': height,
        'position': position.name,
        'showName': showName,
      };

  DocumentLogoLayout copyWith({
    double? height,
    DocumentLogoPosition? position,
    bool? showName,
  }) =>
      DocumentLogoLayout(
        height: (height ?? this.height).clamp(minHeight, maxHeight).toDouble(),
        position: position ?? this.position,
        showName: showName ?? this.showName,
      );

  @override
  bool operator ==(Object other) =>
      other is DocumentLogoLayout &&
      other.height == height &&
      other.position == position &&
      other.showName == showName;

  @override
  int get hashCode => Object.hash(height, position, showName);

  @override
  String toString() =>
      'DocumentLogoLayout(height: $height, position: ${position.name}, showName: $showName)';
}
