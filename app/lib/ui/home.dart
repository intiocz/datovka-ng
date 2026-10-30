import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'directory.dart';
import 'message_detail.dart';
import 'message_list.dart';
import 'sidebar.dart';
import 'status_bar.dart';

/// Three panes on wide screens; list and detail side by side on a tablet held
/// upright; list with drawer and pushed detail on narrow ones. The sidebar of
/// the last two is in the drawer.
class Home extends StatelessWidget {
  const Home({super.key});

  static const wide = 980.0;

  /// List and detail fit side by side from here, on a screen tall enough not
  /// to be a phone on its side.
  static const medium = 700.0;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);

    return _Keys(
      state: s,
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth >= wide) {
            return const Scaffold(
              bottomNavigationBar: StatusBar(),
              body: _WidePanes(),
            );
          }
          return Scaffold(
            bottomNavigationBar: const StatusBar(),
            drawer: Drawer(
              width: 290,
              shape: const RoundedRectangleBorder(),
              child: Builder(
                builder: (ctx) =>
                    Sidebar(onPicked: () => Navigator.of(ctx).pop()),
              ),
            ),
            body: Builder(
              builder: (ctx) {
                final menu = IconButton(
                  tooltip: 'Schránky a složky',
                  icon: const Icon(Icons.menu),
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                );
                if (s.view == Screen.directory) {
                  return DirectoryView(leading: menu);
                }
                if (c.maxWidth >= medium && c.maxHeight >= 560) {
                  final t = Tokens.of(ctx);
                  final m = s.selected;
                  return Row(
                    children: [
                      SizedBox(
                        width: c.maxWidth >= 900 ? 380 : 340,
                        child: MessageList(
                          leading: menu,
                          onOpen: (m) => s.open(m.dmId),
                        ),
                      ),
                      VerticalDivider(width: 1, color: t.line),
                      Expanded(
                        child: m == null
                            ? const NoSelection()
                            : MessageDetail(key: ValueKey(m.dmId), m: m),
                      ),
                    ],
                  );
                }
                return MessageList(
                  leading: menu,
                  onOpen: (m) {
                    s.open(m.dmId);
                    Navigator.of(ctx).push(
                      MaterialPageRoute(
                        builder: (_) => Scaffold(
                          body: ListenableBuilder(
                            listenable: s,
                            builder: (_, _) {
                              final cur = s.selected ?? m;
                              return MessageDetail(m: cur, showBack: true);
                            },
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// ⌘F focuses search. Arrows move the selection unless a text field has it.
class _Keys extends StatefulWidget {
  final AppState state;
  final Widget child;

  const _Keys({required this.state, required this.child});

  @override
  State<_Keys> createState() => _KeysState();
}

class _KeysState extends State<_Keys> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    final typing = FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    final keys = HardwareKeyboard.instance;
    final command = keys.isMetaPressed || keys.isControlPressed;
    if (command && e.logicalKey == LogicalKeyboardKey.keyF) {
      widget.state.searchFocus.requestFocus();
      return true;
    }
    if (typing) return false;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      widget.state.moveSelection(1);
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      widget.state.moveSelection(-1);
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && widget.state.picked.isNotEmpty) {
      widget.state.clearPicked();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Sidebar, list and detail side by side. The two dividers can be dragged;
/// the widths are kept in preferences, so they survive restarts and updates.
/// A double click on a divider restores the default width.
class _WidePanes extends StatefulWidget {
  const _WidePanes();

  @override
  State<_WidePanes> createState() => _WidePanesState();
}

class _WidePanesState extends State<_WidePanes> {
  static const _sidebarKey = 'paneSidebarWidth';
  static const _listKey = 'paneListWidth';
  static const _sidebarDefault = 260.0;
  static const _minSidebar = 200.0;
  static const _maxSidebar = 420.0;
  static const _minList = 280.0;
  static const _minDetail = 360.0;

  double _sidebar = _sidebarDefault;
  double? _list;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _sidebar = p.getDouble(_sidebarKey) ?? _sidebar;
        _list = p.getDouble(_listKey) ?? _list;
      });
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_sidebarKey, _sidebar);
    final list = _list;
    if (list == null) {
      await p.remove(_listKey);
    } else {
      await p.setDouble(_listKey, list);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final m = s.selected;
    return LayoutBuilder(
      builder: (context, c) {
        final sidebar = _sidebar.clamp(_minSidebar, _maxSidebar);
        final listDefault = c.maxWidth >= 1280 ? 420.0 : 360.0;
        final listMax = (c.maxWidth - sidebar - _minDetail - 2).clamp(
          _minList,
          double.infinity,
        );
        final list = (_list ?? listDefault).clamp(_minList, listMax);
        final t = Tokens.of(context);
        final directory = s.view == Screen.directory;
        return Stack(
          children: [
            Row(
              children: [
                SizedBox(width: sidebar, child: const Sidebar()),
                VerticalDivider(width: 1, color: t.line),
                if (directory)
                  const Expanded(child: DirectoryView())
                else ...[
                  SizedBox(
                    width: list,
                    child: MessageList(onOpen: (m) => s.open(m.dmId)),
                  ),
                  VerticalDivider(width: 1, color: t.line),
                  Expanded(
                    child: m == null
                        ? const NoSelection()
                        : MessageDetail(key: ValueKey(m.dmId), m: m),
                  ),
                ],
              ],
            ),
            _PaneHandle(
              at: sidebar,
              width: sidebar,
              onDrag: (w) => setState(() => _sidebar = w),
              onEnd: _save,
              onReset: () {
                setState(() => _sidebar = _sidebarDefault);
                _save();
              },
            ),
            if (!directory)
              _PaneHandle(
                at: sidebar + 1 + list,
                width: list,
                onDrag: (w) => setState(() => _list = w),
                onEnd: _save,
                onReset: () {
                  setState(() => _list = null);
                  _save();
                },
              ),
          ],
        );
      },
    );
  }
}

/// Invisible strip over the divider at [at]; it shows a resize cursor and
/// highlights the line while hovered. [onDrag] gets the new [width] of the
/// pane on its left, following the pointer from where the drag started.
class _PaneHandle extends StatefulWidget {
  final double at;
  final double width;
  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;
  final VoidCallback onReset;

  const _PaneHandle({
    required this.at,
    required this.width,
    required this.onDrag,
    required this.onEnd,
    required this.onReset,
  });

  @override
  State<_PaneHandle> createState() => _PaneHandleState();
}

class _PaneHandleState extends State<_PaneHandle> {
  static const _width = 9.0;
  var _active = false;
  var _startX = 0.0;
  var _startWidth = 0.0;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Positioned(
      left: widget.at - (_width - 1) / 2,
      top: 0,
      bottom: 0,
      width: _width,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _active = true),
        onExit: (_) => setState(() => _active = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: (d) {
            _startX = d.globalPosition.dx;
            _startWidth = widget.width;
          },
          onHorizontalDragUpdate: (d) =>
              widget.onDrag(_startWidth + d.globalPosition.dx - _startX),
          onHorizontalDragEnd: (_) => widget.onEnd(),
          onDoubleTap: widget.onReset,
          child: Center(
            child: Container(
              width: 3,
              color: _active ? t.accent : Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}
