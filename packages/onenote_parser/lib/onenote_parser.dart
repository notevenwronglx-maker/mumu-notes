import 'dart:typed_data';

class RustLib {
  static Future<void> init() async {}
}

Future<OneNoteNotebook> parsePackageBytes({required Uint8List data}) async {
  return const OneNoteNotebook(
    entries: [],
    warnings: [
      OneNoteWarning(
        message: 'OneNote binary parser running in pure-Dart mode.',
      ),
    ],
  );
}

Future<OneNoteSection> parseSectionBytes({
  required Uint8List data,
  required String fileName,
}) async {
  final displayName = fileName.endsWith('.one')
      ? fileName.substring(0, fileName.length - 4)
      : fileName;
  return OneNoteSection(
    displayName: displayName,
    pageSeries: const [],
    warnings: const [
      OneNoteWarning(
        message: 'OneNote binary parser running in pure-Dart mode.',
      ),
    ],
  );
}

class OneNoteWarning {
  final String message;
  final String? pageId;

  const OneNoteWarning({required this.message, this.pageId});
}

class OneNoteNotebook {
  final List<OneNoteSectionEntry> entries;
  final List<OneNoteWarning> warnings;

  const OneNoteNotebook({
    this.entries = const [],
    this.warnings = const [],
  });
}

class OneNoteSectionGroup {
  final String displayName;
  final List<OneNoteSectionEntry> entries;

  const OneNoteSectionGroup({
    required this.displayName,
    this.entries = const [],
  });
}

class OneNoteSectionEntry {
  final OneNoteSection? _section;
  final OneNoteSectionGroup? _sectionGroup;

  const OneNoteSectionEntry.section(OneNoteSection this._section)
      : _sectionGroup = null;

  const OneNoteSectionEntry.sectionGroup(OneNoteSectionGroup this._sectionGroup)
      : _section = null;

  T when<T>({
    required T Function(OneNoteSection section) section,
    required T Function(OneNoteSectionGroup group) sectionGroup,
  }) {
    if (_section != null) return section(_section);
    return sectionGroup(_sectionGroup!);
  }
}

class OneNoteSection {
  final String displayName;
  final List<OneNotePageSeries> pageSeries;
  final List<OneNoteWarning> warnings;

  const OneNoteSection({
    required this.displayName,
    this.pageSeries = const [],
    this.warnings = const [],
  });
}

class OneNotePageSeries {
  final List<OneNotePage> pages;

  const OneNotePageSeries({this.pages = const []});
}

class OneNotePage {
  final String? linkTargetId;
  final String? title;
  final int level;
  final String? author;
  final String createdAt;
  final String updatedAt;
  final String? recognizedText;
  final List<OneNotePageContent> contents;

  const OneNotePage({
    this.linkTargetId,
    this.title,
    this.level = 0,
    this.author,
    this.createdAt = '',
    this.updatedAt = '',
    this.recognizedText,
    this.contents = const [],
  });
}

class OneNotePageContent {
  final OneNoteOutline? _outline;
  final OneNoteImage? _image;
  final OneNoteEmbeddedFile? _embeddedFile;
  final OneNoteInk? _ink;

  const OneNotePageContent.outline(OneNoteOutline this._outline)
      : _image = null,
        _embeddedFile = null,
        _ink = null;

  const OneNotePageContent.image(OneNoteImage this._image)
      : _outline = null,
        _embeddedFile = null,
        _ink = null;

  const OneNotePageContent.embeddedFile(OneNoteEmbeddedFile this._embeddedFile)
      : _outline = null,
        _image = null,
        _ink = null;

  const OneNotePageContent.ink(OneNoteInk this._ink)
      : _outline = null,
        _image = null,
        _embeddedFile = null;

  const OneNotePageContent.unknown()
      : _outline = null,
        _image = null,
        _embeddedFile = null,
        _ink = null;

  T when<T>({
    required T Function(OneNoteOutline outline) outline,
    required T Function(OneNoteImage image) image,
    required T Function(OneNoteEmbeddedFile embeddedFile) embeddedFile,
    required T Function(OneNoteInk ink) ink,
    required T Function() unknown,
  }) {
    if (_outline != null) return outline(_outline);
    if (_image != null) return image(_image);
    if (_embeddedFile != null) return embeddedFile(_embeddedFile);
    if (_ink != null) return ink(_ink);
    return unknown();
  }
}

class OneNoteOutline {
  final int childLevel;
  final Float32List indents;
  final bool isLayoutSizeSetByUser;
  final double? layoutMaxWidth;
  final double? layoutMaxHeight;
  final double? offsetHorizontal;
  final double? offsetVertical;
  final List<OneNoteOutlineItem> items;

  const OneNoteOutline({
    this.childLevel = 0,
    required this.indents,
    this.isLayoutSizeSetByUser = false,
    this.layoutMaxWidth,
    this.layoutMaxHeight,
    this.offsetHorizontal,
    this.offsetVertical,
    this.items = const [],
  });
}

class OneNoteOutlineGroup {
  final int childLevel;
  final List<OneNoteOutlineItem> items;

  const OneNoteOutlineGroup({
    this.childLevel = 0,
    this.items = const [],
  });
}

class OneNoteOutlineItem {
  final OneNoteOutlineGroup? _group;
  final OneNoteOutlineElement? _element;

  const OneNoteOutlineItem.group(OneNoteOutlineGroup this._group)
      : _element = null;

  const OneNoteOutlineItem.element(OneNoteOutlineElement this._element)
      : _group = null;

  T when<T>({
    required T Function(OneNoteOutlineGroup group) group,
    required T Function(OneNoteOutlineElement element) element,
  }) {
    if (_group != null) return group(_group);
    return element(_element!);
  }
}

class OneNoteOutlineElement {
  final List<OneNoteContent> contents;
  final int childLevel;
  final List<OneNoteOutlineItem> children;

  const OneNoteOutlineElement({
    this.contents = const [],
    this.childLevel = 0,
    this.children = const [],
  });
}

class OneNoteContent {
  final OneNoteRichText? _richText;
  final OneNoteTable? _table;
  final OneNoteImage? _image;
  final OneNoteEmbeddedFile? _embeddedFile;
  final OneNoteInk? _ink;

  const OneNoteContent.richText(OneNoteRichText this._richText)
      : _table = null,
        _image = null,
        _embeddedFile = null,
        _ink = null;

  const OneNoteContent.table(OneNoteTable this._table)
      : _richText = null,
        _image = null,
        _embeddedFile = null,
        _ink = null;

  const OneNoteContent.image(OneNoteImage this._image)
      : _richText = null,
        _table = null,
        _embeddedFile = null,
        _ink = null;

  const OneNoteContent.embeddedFile(OneNoteEmbeddedFile this._embeddedFile)
      : _richText = null,
        _table = null,
        _image = null,
        _ink = null;

  const OneNoteContent.ink(OneNoteInk this._ink)
      : _richText = null,
        _table = null,
        _image = null,
        _embeddedFile = null;

  const OneNoteContent.unknown()
      : _richText = null,
        _table = null,
        _image = null,
        _embeddedFile = null,
        _ink = null;

  T when<T>({
    required T Function(OneNoteRichText richText) richText,
    required T Function(OneNoteTable table) table,
    required T Function(OneNoteImage image) image,
    required T Function(OneNoteEmbeddedFile embeddedFile) embeddedFile,
    required T Function(OneNoteInk ink) ink,
    required T Function() unknown,
  }) {
    if (_richText != null) return richText(_richText);
    if (_table != null) return table(_table);
    if (_image != null) return image(_image);
    if (_embeddedFile != null) return embeddedFile(_embeddedFile);
    if (_ink != null) return ink(_ink);
    return unknown();
  }
}

class OneNoteRichText {
  final String text;
  final Uint32List textRunIndices;
  final List<OneNoteTextStyle> textRunStyles;
  final OneNoteTextStyle paragraphStyle;
  final double paragraphSpaceBefore;
  final double paragraphSpaceAfter;
  final String paragraphAlignment;
  final List<OneNoteEmbeddedObject> embeddedObjects;

  const OneNoteRichText({
    required this.text,
    required this.textRunIndices,
    this.textRunStyles = const [],
    required this.paragraphStyle,
    this.paragraphSpaceBefore = 0,
    this.paragraphSpaceAfter = 0,
    this.paragraphAlignment = 'Left',
    this.embeddedObjects = const [],
  });
}

class OneNoteTextStyle {
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final bool superscript;
  final bool subscript;
  final String? font;
  final int? fontSize;
  final OneNoteColor? fontColor;
  final OneNoteColor? highlight;
  final bool mathFormatting;
  final bool hyperlink;
  final bool hyperlinkProtected;
  final bool hidden;

  const OneNoteTextStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.superscript = false,
    this.subscript = false,
    this.font,
    this.fontSize,
    this.fontColor,
    this.highlight,
    this.mathFormatting = false,
    this.hyperlink = false,
    this.hyperlinkProtected = false,
    this.hidden = false,
  });
}

class OneNoteEmbeddedInk {
  final OneNoteInk ink;
  final OneNoteInkBoundingBox? displayBoundingBox;

  const OneNoteEmbeddedInk({
    required this.ink,
    this.displayBoundingBox,
  });
}

class OneNoteEmbeddedInkSpace {
  final double width;
  final double height;

  const OneNoteEmbeddedInkSpace({
    required this.width,
    required this.height,
  });
}

class OneNoteEmbeddedObject {
  final OneNoteEmbeddedInk? _ink;
  final OneNoteEmbeddedInkSpace? _inkSpace;

  const OneNoteEmbeddedObject.ink(OneNoteEmbeddedInk this._ink)
      : _inkSpace = null;

  const OneNoteEmbeddedObject.inkSpace(OneNoteEmbeddedInkSpace this._inkSpace)
      : _ink = null;

  const OneNoteEmbeddedObject.inkLineBreak()
      : _ink = null,
        _inkSpace = null;

  T when<T>({
    required T Function(OneNoteEmbeddedInk embedded) ink,
    required T Function(OneNoteEmbeddedInkSpace space) inkSpace,
    required T Function() inkLineBreak,
  }) {
    if (_ink != null) return ink(_ink);
    if (_inkSpace != null) return inkSpace(_inkSpace);
    return inkLineBreak();
  }
}

class OneNoteColor {
  final int alpha;
  final int red;
  final int green;
  final int blue;

  const OneNoteColor({
    required this.alpha,
    required this.red,
    required this.green,
    required this.blue,
  });
}

class OneNoteTable {
  final int rowCount;
  final int columnCount;
  final List<OneNoteTableRow> rows;
  final Uint8List lockedColumns;
  final Float32List columnWidths;
  final bool bordersVisible;

  const OneNoteTable({
    required this.rowCount,
    required this.columnCount,
    this.rows = const [],
    required this.lockedColumns,
    required this.columnWidths,
    this.bordersVisible = true,
  });
}

class OneNoteTableRow {
  final List<OneNoteTableCell> cells;

  const OneNoteTableRow({this.cells = const []});
}

class OneNoteTableCell {
  final List<OneNoteOutlineElement> contents;
  final OneNoteColor? backgroundColor;
  final Float32List indents;

  const OneNoteTableCell({
    this.contents = const [],
    this.backgroundColor,
    required this.indents,
  });
}

class OneNoteImage {
  final Uint8List? data;
  final String? extension_;
  final String? filename;
  final String? altText;
  final String? ocrText;
  final String? hyperlinkUrl;
  final double? layoutMaxWidth;
  final double? layoutMaxHeight;
  final double? pictureWidth;
  final double? pictureHeight;
  final double? offsetHorizontal;
  final double? offsetVertical;
  final int? displayedPageNumber;
  final bool isBackground;

  const OneNoteImage({
    this.data,
    this.extension_,
    this.filename,
    this.altText,
    this.ocrText,
    this.hyperlinkUrl,
    this.layoutMaxWidth,
    this.layoutMaxHeight,
    this.pictureWidth,
    this.pictureHeight,
    this.offsetHorizontal,
    this.offsetVertical,
    this.displayedPageNumber,
    this.isBackground = false,
  });
}

class OneNoteEmbeddedFile {
  final String filename;
  final String fileType;
  final Uint8List data;
  final BigInt size;
  final double? offsetHorizontal;
  final double? offsetVertical;

  const OneNoteEmbeddedFile({
    required this.filename,
    required this.fileType,
    required this.data,
    required this.size,
    this.offsetHorizontal,
    this.offsetVertical,
  });
}

class OneNoteInk {
  final List<OneNoteInkStroke> strokes;
  final List<OneNoteInk> childGroups;
  final OneNoteInkBoundingBox? boundingBox;
  final double? offsetHorizontal;
  final double? offsetVertical;

  const OneNoteInk({
    this.strokes = const [],
    this.childGroups = const [],
    this.boundingBox,
    this.offsetHorizontal,
    this.offsetVertical,
  });
}

class OneNoteInkBoundingBox {
  final double x;
  final double y;
  final double width;
  final double height;

  const OneNoteInkBoundingBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

class OneNoteInkStroke {
  final List<OneNoteInkPoint> path;
  final int? penTip;
  final int? transparency;
  final double height;
  final double width;
  final int? color;
  final String? recognizedText;

  const OneNoteInkStroke({
    this.path = const [],
    this.penTip,
    this.transparency,
    required this.height,
    required this.width,
    this.color,
    this.recognizedText,
  });
}

class OneNoteInkPoint {
  final double x;
  final double y;

  const OneNoteInkPoint({
    required this.x,
    required this.y,
  });
}
