import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/handlers/handler.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:butterfly_api/butterfly_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:keybinder/keybinder.dart';

import '../cubits/editor_controller.dart';

class SelectAllIntent extends Intent {
  const SelectAllIntent();
}

const selectAllShortcut = ShortcutDefinition(
  id: 'select_all',
  intent: SelectAllIntent(),
  defaultActivator: SingleActivator(LogicalKeyboardKey.keyA, control: true),
);

class SelectAllAction extends Action<SelectAllIntent> {
  final BuildContext context;

  SelectAllAction(this.context);

  @override
  Future<void> invoke(SelectAllIntent intent) async {
    final cubit = context.read<EditorController>();
    final bloc = context.read<DocumentBloc>();
    final activeHandler = cubit.toolCubit.getHandler(
      editable: cubit.saveCubit.state.embedding?.editable != false,
    );
    if (activeHandler is SelectHandler) {
      activeHandler.selectAll(bloc);
      return;
    }
    final handler = await cubit.toolCubit.changeTemporaryHandler(
      context,
      cubit,
      SelectTool(),
      bloc: bloc,
      temporaryState: TemporaryState.removeAfterClick,
    );
    if (handler is! SelectHandler) return;
    handler.selectAll(bloc);
  }
}
