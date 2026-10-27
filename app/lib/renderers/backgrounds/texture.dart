part of '../renderer.dart';

class TextureBackgroundRenderer extends Renderer<TextureBackground> {
  TextureBackgroundRenderer(super.element);

  SurfaceTexture get texture => element.texture;

  @override
  void build(
    Canvas canvas,
    Size size,
    NoteData document,
    DocumentPage page,
    DocumentInfo info,
    CameraTransform transform, [
    ColorScheme? colorScheme,
    bool foreground = false,
  ]) {
    final viewport = transform.localToGlobalRect(
      (Offset.zero & size).inflate(20),
    );

    if (page.isMumuInfiniteCanvas(info)) {
      drawSurfaceTextureOnCanvas(
        texture,
        canvas,
        1,
        viewport.topLeft,
        viewport.size,
        viewport.topLeft,
        true,
      );
      return;
    }

    // Mumu 标准分页模式：将背景纹理严格裁剪并对齐在每一页纸张 (Area) 内部
    for (final sheet in page.resolvedPageSheets) {
      final rect = sheet.rect;
      if (!rect.overlaps(viewport)) continue;
      canvas.save();
      canvas.clipRect(rect);
      drawSurfaceTextureOnCanvas(
        texture,
        canvas,
        1,
        Offset.zero,
        rect.size,
        rect.topLeft,
        false,
      );
      canvas.restore();
    }
  }

  @override
  void buildSvg(
    XmlDocument xml,
    NoteData document,
    DocumentPage page,
    Rect viewportRect,
  ) => drawSurfaceTextureOnSvg(
    texture,
    xml,
    Offset.zero,
    viewportRect.size,
    viewportRect.topLeft,
    true,
  );
}
