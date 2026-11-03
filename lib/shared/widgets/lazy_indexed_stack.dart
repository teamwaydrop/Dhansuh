import 'package:flutter/material.dart';

/// Mount each keyed child once, on first selection, then retain its State.
/// Keys also preserve identity when rider service mode changes the tab list.
class LazyIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  final Set<int> eagerIndices;
  const LazyIndexedStack({
    super.key,
    required this.index,
    required this.children,
    this.eagerIndices = const {},
  });

  @override
  State<LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<LazyIndexedStack> {
  final Set<Key> _visited = {};

  @override
  Widget build(BuildContext context) {
    assert(widget.children.every((child) => child.key != null));
    _visited.add(widget.children[widget.index].key!);
    for (final i in widget.eagerIndices) {
      _visited.add(widget.children[i].key!);
    }
    return IndexedStack(
      index: widget.index,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          if (_visited.contains(widget.children[i].key))
            TickerMode(
              key: ValueKey(widget.children[i].key),
              enabled: i == widget.index,
              child: widget.children[i],
            )
          else
            SizedBox.shrink(key: widget.children[i].key),
      ],
    );
  }
}
