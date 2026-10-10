import 'package:flutter/material.dart';

/// 骨架屏占位块（呼吸动画的灰块）。
class SkeletonBlock extends StatefulWidget {
  const SkeletonBlock({
    super.key,
    this.width = double.infinity,
    this.height = 14,
    this.radius = 6,
  });

  final double width;
  final double height;
  final double radius;

  @override
  State<SkeletonBlock> createState() => _SkeletonBlockState();
}

class _SkeletonBlockState extends State<SkeletonBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 0.9)
          .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// 曲目列表骨架（leading 方块 + 标题/副标题两行）。
class SkeletonTrackList extends StatelessWidget {
  const SkeletonTrackList({super.key, this.count = 8});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(count, (_) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              const SkeletonBlock(width: 48, height: 48, radius: 6),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    SkeletonBlock(width: 190, height: 15),
                    SizedBox(height: 8),
                    SkeletonBlock(width: 120, height: 12),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// 骨架页：居中容器包住列表骨架（替代首载菊花）。
class SkeletonBody extends StatelessWidget {
  const SkeletonBody({super.key, this.count = 8});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: SkeletonTrackList(count: count),
    );
  }
}

/// 骨架网格（歌单封面网格用：方块 + 底下两行）。
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({super.key, this.count = 6, this.columns = 3});

  final int count;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: columns,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 0.72,
      children: List.generate(count, (_) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Expanded(child: SkeletonBlock(width: double.infinity, radius: 8)),
            SizedBox(height: 8),
            SkeletonBlock(height: 13),
            SizedBox(height: 5),
            SkeletonBlock(width: 70, height: 11),
          ],
        );
      }),
    );
  }
}
