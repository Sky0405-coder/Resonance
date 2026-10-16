import 'package:flutter/material.dart';

class SheetAction {
  const SheetAction({required this.icon, required this.label, required this.onSelected});

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
}

Future<void> showActionSheet(BuildContext context, {required Widget header, required List<SheetAction> actions}) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF282828),
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              header,
              const Divider(),
              for (final action in actions)
                ListTile(
                  leading: Icon(action.icon),
                  title: Text(action.label),
                  onTap: () {
                    Navigator.pop(sheet);
                    action.onSelected();
                  },
                ),
            ],
          ),
        ),
      ),
    );
