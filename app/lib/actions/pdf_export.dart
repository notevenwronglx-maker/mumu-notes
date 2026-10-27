import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:keybinder/keybinder.dart';

import '../helpers/page.dart';
import '../dialogs/export/pdf.dart';

class PdfExportIntent extends Intent {
  const PdfExportIntent();
}

const pdfExportShortcut = ShortcutDefinition(
  id: 'pdf_export',
  intent: PdfExportIntent(),
  defaultActivator: SingleActivator(
    LogicalKeyboardKey.keyP,
    control: true,
    shift: true,
  ),
);

class PdfExportAction extends Action<PdfExportIntent> {
  final BuildContext context;

  PdfExportAction(this.context);

  @override
  Future<void> invoke(PdfExportIntent intent) async {
    final bloc = context.read<DocumentBloc>();
    final state = bloc.state;
    if (state is! DocumentLoadSuccess) return;
    // 导出整本笔记的所有纸页（DocumentPage 的各个 Area），而不是仅当前视口
    final areas = <AreaPreset>[];
    for (final pageName in state.data.getPages(true)) {
      final page = pageName == state.pageName
          ? state.page
          : state.data.getPage(pageName);
      if (page == null) continue;
      for (final area in page.resolvedPageSheets) {
        areas.add(
          AreaPreset(name: area.name, page: pageName, area: area),
        );
      }
    }
    if (areas.isEmpty) {
      areas.add(
        state.areaPreset(
          bloc.editorController.rendererCubit.state.cameraViewport,
        ),
      );
    }
    if (context.mounted) {
      return showDialog<void>(
        builder: (context) => BlocProvider.value(
          value: bloc,
          child: PdfExportDialog(areas: areas),
        ),
        context: context,
      );
    }
  }
}
