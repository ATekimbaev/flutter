// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'finders.dart';
import 'widget_tester.dart';

/// The result of evaluating a semantics node by a [AccessibilityGuideline].
class Evaluation {
  /// Create a passing evaluation.
  const Evaluation.pass()
      : passed = true,
        reason = null;

  /// Create a failing evaluation, with an optional [reason] explaining the
  /// result.
  const Evaluation.fail([this.reason]) : passed = false;

  // private constructor for adding cases together.
  const Evaluation._(this.passed, this.reason);

  /// Whether the given tree or node passed the policy evaluation.
  final bool passed;

  /// If [passed] is false, contains the reason for failure.
  final String? reason;

  /// Combines two evaluation results.
  ///
  /// The [reason] will be concatenated with a newline, and [passed] will be
  /// combined with an `&&` operator.
  Evaluation operator +(Evaluation? other) {
    if (other == null) {
      return this;
    }

    final StringBuffer buffer = StringBuffer();
    if (reason != null) {
      buffer.write(reason);
      buffer.write(' ');
    }
    if (other.reason != null) {
      buffer.write(other.reason);
    }
    return Evaluation._(
      passed && other.passed,
      buffer.isEmpty ? null : buffer.toString(),
    );
  }
}

/// An accessibility guideline describes a recommendation an application should
/// meet to be considered accessible.
abstract class AccessibilityGuideline {
  /// A const constructor allows subclasses to be const.
  const AccessibilityGuideline();

  /// Evaluate whether the current state of the `tester` conforms to the rule.
  FutureOr<Evaluation> evaluate(WidgetTester tester);

  /// A description of the policy restrictions and criteria.
  String get description;
}

/// A guideline which enforces that all tappable semantics nodes have a minimum
/// size.
///
/// Each platform defines its own guidelines for minimum tap areas.
@visibleForTesting
class MinimumTapTargetGuideline extends AccessibilityGuideline {
  /// Create a new [MinimumTapTargetGuideline].
  const MinimumTapTargetGuideline({required this.size, required this.link});

  /// The minimum allowed size of a tappable node.
  final Size size;

  /// A link describing the tap target guidelines for a platform.
  final String link;

  @override
  FutureOr<Evaluation> evaluate(WidgetTester tester) {
    return _traverse(
      tester,
      tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!,
    );
  }

  Evaluation _traverse(WidgetTester tester, SemanticsNode node) {
    Evaluation result = const Evaluation.pass();
    node.visitChildren((SemanticsNode child) {
      result += _traverse(tester, child);
      return true;
    });
    if (node.isMergedIntoParent) {
      return result;
    }
    if (shouldSkipNode(node)) {
      return result;
    }
    Rect paintBounds = node.rect;
    SemanticsNode? current = node;
    while (current != null) {
      final Matrix4? transform = current.transform;
      if (transform != null) {
        paintBounds = MatrixUtils.transformRect(transform, paintBounds);
      }
      current = current.parent;
    }
    // skip node if it is touching the edge of the screen, since it might
    // be partially scrolled offscreen.
    const double delta = 0.001;
    final Size physicalSize = tester.binding.window.physicalSize;
    if (paintBounds.left <= delta ||
        paintBounds.top <= delta ||
        (paintBounds.bottom - physicalSize.height).abs() <= delta ||
        (paintBounds.right - physicalSize.width).abs() <= delta) {
      return result;
    }
    // shrink by device pixel ratio.
    final Size candidateSize = paintBounds.size / tester.binding.window.devicePixelRatio;
    if (candidateSize.width < size.width - delta ||
        candidateSize.height < size.height - delta) {
      result += Evaluation.fail(
        '$node: expected tap target size of at least $size, '
        'but found $candidateSize\n'
        'See also: $link',
      );
    }
    return result;
  }

  /// Returns whether [SemanticsNode] should be skipped for minimum tap target
  /// guideline.
  ///
  /// Skips nodes which are link, hidden, or do not have actions.
  bool shouldSkipNode(SemanticsNode node) {
    final SemanticsData data = node.getSemanticsData();
    // Skip node if it has no actions, or is marked as hidden.
    if ((!data.hasAction(ui.SemanticsAction.longPress) &&
            !data.hasAction(ui.SemanticsAction.tap)) ||
        data.hasFlag(ui.SemanticsFlag.isHidden)) {
      return true;
    }
    // Skip links https://www.w3.org/WAI/WCAG21/Understanding/target-size.html
    if (data.hasFlag(ui.SemanticsFlag.isLink)) {
      return true;
    }
    return false;
  }

  @override
  String get description => 'Tappable objects should be at least $size';
}

/// A guideline which enforces that all nodes with a tap or long press action
/// also have a label.
@visibleForTesting
class LabeledTapTargetGuideline extends AccessibilityGuideline {
  const LabeledTapTargetGuideline._();

  @override
  String get description => 'Tappable widgets should have a semantic label';

  @override
  FutureOr<Evaluation> evaluate(WidgetTester tester) {
    final SemanticsNode root = tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
    Evaluation traverse(SemanticsNode node) {
      Evaluation result = const Evaluation.pass();
      node.visitChildren((SemanticsNode child) {
        result += traverse(child);
        return true;
      });
      if (node.isMergedIntoParent ||
          node.isInvisible ||
          node.hasFlag(ui.SemanticsFlag.isHidden)) {
        return result;
      }
      final SemanticsData data = node.getSemanticsData();
      // Skip node if it has no actions, or is marked as hidden.
      if (!data.hasAction(ui.SemanticsAction.longPress) &&
          !data.hasAction(ui.SemanticsAction.tap)) {
        return result;
      }
      if (data.label == null || data.label.isEmpty) {
        result += Evaluation.fail(
          '$node: expected tappable node to have semantic label, '
          'but none was found.\n',
        );
      }
      return result;
    }

    return traverse(root);
  }
}

/// A guideline which verifies that all nodes that contribute semantics via text
/// meet minimum contrast levels.
///
/// The guidelines are defined by the Web Content Accessibility Guidelines,
/// http://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html.
@visibleForTesting
class MinimumTextContrastGuideline extends AccessibilityGuideline {
  /// Create a new [MinimumTextContrastGuideline].
  const MinimumTextContrastGuideline();

  /// The minimum text size considered large for contrast checking.
  ///
  /// Defined by http://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html
  static const int kLargeTextMinimumSize = 18;

  /// The minimum text size for bold text to be considered large for contrast
  /// checking.
  ///
  /// Defined by http://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html
  static const int kBoldTextMinimumSize = 14;

  /// The minimum contrast ratio for normal text.
  ///
  /// Defined by http://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html
  static const double kMinimumRatioNormalText = 4.5;

  /// The minimum contrast ratio for large text.
  ///
  /// Defined by http://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html
  static const double kMinimumRatioLargeText = 3.0;

  static const double _kDefaultFontSize = 12.0;

  static const double _tolerance = -0.01;

  @override
  Future<Evaluation> evaluate(WidgetTester tester) async {
    final SemanticsNode root = tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
    final RenderView renderView = tester.binding.renderView;
    final OffsetLayer layer = renderView.debugLayer! as OffsetLayer;

    late ui.Image image;
    final ByteData? byteData = await tester.binding.runAsync<ByteData?>(
      () async {
        // Needs to be the same pixel ratio otherwise our dimensions won't match
        // the last transform layer.
        final double ratio = 1 / tester.binding.window.devicePixelRatio;
        image = await layer.toImage(renderView.paintBounds, pixelRatio: ratio);
        return image.toByteData();
      },
    );

    return _evaluateNode(root, tester, image, byteData!);
  }

  Future<Evaluation> _evaluateNode(
    SemanticsNode node,
    WidgetTester tester,
    ui.Image image,
    ByteData byteData,
  ) async {
    Evaluation result = const Evaluation.pass();

    // Skip disabled nodes, as they not required to pass contrast check.
    final bool isDisabled = node.hasFlag(ui.SemanticsFlag.hasEnabledState) &&
        !node.hasFlag(ui.SemanticsFlag.isEnabled);

    if (node.isInvisible ||
        node.isMergedIntoParent ||
        node.hasFlag(ui.SemanticsFlag.isHidden) ||
        isDisabled) {
      return result;
    }

    final SemanticsData data = node.getSemanticsData();
    final List<SemanticsNode> children = <SemanticsNode>[];
    node.visitChildren((SemanticsNode child) {
      children.add(child);
      return true;
    });
    for (final SemanticsNode child in children) {
      result += await _evaluateNode(child, tester, image, byteData);
    }
    if (shouldSkipNode(data)) {
      return result;
    }

    // Look up inherited text properties to determine text size and weight.
    late bool isBold;
    double? fontSize;

    final String text = data.label.isEmpty ? data.value : data.label;
    final List<Element> elements = find.text(text).hitTestable().evaluate().toList();
    late final Rect paintBounds;

    if (elements.length == 1) {
      final Element element = elements.single;
      final RenderObject? renderBox = element.renderObject;
      if (renderBox is! RenderBox) {
        throw StateError('Unexpected renderObject type: $renderBox');
      }

      const Offset offset = Offset(4.0, 4.0);
      paintBounds = Rect.fromPoints(
        renderBox.localToGlobal(renderBox.paintBounds.topLeft - offset),
        renderBox.localToGlobal(renderBox.paintBounds.bottomRight + offset),
      );
      final Widget widget = element.widget;
      final DefaultTextStyle defaultTextStyle = DefaultTextStyle.of(element);
      if (widget is Text) {
        final TextStyle? style = widget.style;
        final TextStyle effectiveTextStyle = style == null || style.inherit
            ? defaultTextStyle.style.merge(widget.style)
            : style;
        isBold = effectiveTextStyle.fontWeight == FontWeight.bold;
        fontSize = effectiveTextStyle.fontSize;
      } else if (widget is EditableText) {
        isBold = widget.style.fontWeight == FontWeight.bold;
        fontSize = widget.style.fontSize;
      } else {
        throw StateError('Unexpected widget type: ${widget.runtimeType}');
      }
    } else if (elements.length > 1) {
      return Evaluation.fail(
        'Multiple nodes with the same label: ${data.label}\n',
      );
    } else {
      // If we can't find the text node then assume the label does not
      // correspond to actual text.
      return result;
    }

    if (isNodeOffScreen(paintBounds, tester.binding.window)) {
      return result;
    }

    final Map<Color, int> colorHistogram = _colorsWithinRect(byteData, paintBounds, image.width, image.height);

    // Node was too far off screen.
    if (colorHistogram.isEmpty) {
      return result;
    }

    final _ContrastReport report = _ContrastReport(colorHistogram);

    final double contrastRatio = report.contrastRatio();
    final double targetContrastRatio = this.targetContrastRatio(fontSize, bold: isBold);

    if (contrastRatio - targetContrastRatio >= _tolerance) {
      return result + const Evaluation.pass();
    }
    return result +
        Evaluation.fail(
          '$node:\n'
          'Expected contrast ratio of at least $targetContrastRatio '
          'but found ${contrastRatio.toStringAsFixed(2)} '
          'for a font size of $fontSize.\n'
          'The computed colors was:\n'
          'light - ${report.lightColor}, dark - ${report.darkColor}\n'
          'See also: '
          'https://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html',
        );
  }

  /// Returns whether node should be skipped.
  ///
  /// Skip routes which might have labels, and nodes without any text.
  bool shouldSkipNode(SemanticsData data) =>
      data.hasFlag(ui.SemanticsFlag.scopesRoute) ||
      (data.label.trim().isEmpty && data.value.trim().isEmpty);

  /// Returns if a rectangle of node is off the screen.
  ///
  /// Allows node to be of screen partially before culling the node.
  bool isNodeOffScreen(Rect paintBounds, ui.FlutterView window) {
    final Size windowPhysicalSize = window.physicalSize * window.devicePixelRatio;
    return paintBounds.top < -50.0 ||
           paintBounds.left < -50.0 ||
           paintBounds.bottom > windowPhysicalSize.height + 50.0 ||
           paintBounds.right > windowPhysicalSize.width + 50.0;
  }

  /// Returns the required contrast ratio for the [fontSize] and [bold] setting.
  ///
  /// Defined by http://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html
  double targetContrastRatio(double? fontSize, {required bool bold}) {
    final double fontSizeOrDefault = fontSize ?? _kDefaultFontSize;
    if ((bold && fontSizeOrDefault >= kBoldTextMinimumSize) ||
        fontSizeOrDefault >= kLargeTextMinimumSize) {
      return kMinimumRatioLargeText;
    }
    return kMinimumRatioNormalText;
  }

  @override
  String get description => 'Text contrast should follow WCAG guidelines';
}

/// A guideline which verifies that all elements specified by [finder]
/// meet minimum contrast levels.
class CustomMinimumContrastGuideline extends AccessibilityGuideline {
  /// Creates a custom guideline which verifies that all elements specified
  /// by [finder] meet minimum contrast levels.
  ///
  /// An optional description string can be given using the [description] parameter.
  const CustomMinimumContrastGuideline({
    required this.finder,
    this.minimumRatio = 4.5,
    this.tolerance = 0.01,
    String description = 'Contrast should follow custom guidelines',
  }) : _description = description;

  /// The minimum contrast ratio allowed.
  ///
  /// Defaults to 4.5, the minimum contrast
  /// ratio for normal text, defined by WCAG.
  /// See http://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html.
  final double minimumRatio;

  /// Tolerance for minimum contrast ratio.
  ///
  /// Any contrast ratio greater than [minimumRatio] or within a distance of [tolerance]
  /// from [minimumRatio] passes the test.
  /// Defaults to 0.01.
  final double tolerance;

  /// The [Finder] used to find a subset of elements.
  ///
  /// [finder] determines which subset of elements will be tested for
  /// contrast ratio.
  final Finder finder;

  final String _description;

  @override
  String get description => _description;

  @override
  Future<Evaluation> evaluate(WidgetTester tester) async {
    // Compute elements to be evaluated.

    final List<Element> elements = finder.evaluate().toList();

    // Obtain rendered image.

    final RenderView renderView = tester.binding.renderView;
    final OffsetLayer layer = renderView.debugLayer! as OffsetLayer;
    late ui.Image image;
    final ByteData? byteData = await tester.binding.runAsync<ByteData?>(
      () async {
        // Needs to be the same pixel ratio otherwise our dimensions won't match
        // the last transform layer.
        final double ratio = 1 / tester.binding.window.devicePixelRatio;
        image = await layer.toImage(renderView.paintBounds, pixelRatio: ratio);
        return image.toByteData();
      },
    );

    // How to evaluate a single element.

    Evaluation evaluateElement(Element element) {
      final RenderBox renderObject = element.renderObject! as RenderBox;

      final Rect originalPaintBounds = renderObject.paintBounds;

      final Rect inflatedPaintBounds = originalPaintBounds.inflate(4.0);

      final Rect paintBounds = Rect.fromPoints(
        renderObject.localToGlobal(inflatedPaintBounds.topLeft),
        renderObject.localToGlobal(inflatedPaintBounds.bottomRight),
      );

      final Map<Color, int> colorHistogram = _colorsWithinRect(byteData!, paintBounds, image.width, image.height);

      if (colorHistogram.isEmpty) {
        return const Evaluation.pass();
      }

      final _ContrastReport report = _ContrastReport(colorHistogram);
      final double contrastRatio = report.contrastRatio();

      if (contrastRatio >= minimumRatio - tolerance) {
        return const Evaluation.pass();
      } else {
        return Evaluation.fail(
          '$element:\nExpected contrast ratio of at least '
          '$minimumRatio but found ${contrastRatio.toStringAsFixed(2)} \n'
          'The computed light color was: ${report.lightColor}, '
          'The computed dark color was: ${report.darkColor}\n'
          '$description',
        );
      }
    }

    // Collate all evaluations into a final evaluation, then return.

    Evaluation result = const Evaluation.pass();

    for (final Element element in elements) {
      result = result + evaluateElement(element);
    }

    return result;
  }
}

/// A class that reports the contrast ratio of a part of the screen.
///
/// Commonly used in accessibility testing to obtain the contrast ratio of
/// text widgets and other types of widgets.
class _ContrastReport {
  /// Generates a contrast report given a color histogram.
  ///
  /// The contrast ratio of the most frequent light color and the most
  /// frequent dark color is calculated. Colors are divided into light and
  /// dark colors based on their lightness as an [HSLColor].
  factory _ContrastReport(Map<Color, int> colorHistogram) {
    // To determine the lighter and darker color, partition the colors
    // by HSL lightness and then choose the mode from each group.
    double totalLightness = 0.0;
    int count = 0;
    for (final MapEntry<Color, int> entry in colorHistogram.entries) {
      totalLightness += HSLColor.fromColor(entry.key).lightness * entry.value;
      count += entry.value;
    }
    final double averageLightness = totalLightness / count;
    assert(averageLightness != double.nan);

    MapEntry<Color, int>? lightColor;
    MapEntry<Color, int>? darkColor;

    // Find the most frequently occurring light and dark color.
    for (final MapEntry<Color, int> entry in colorHistogram.entries) {
      final double lightness = HSLColor.fromColor(entry.key).lightness;
      final int count = entry.value;
      if (lightness <= averageLightness) {
        if (count > (darkColor?.value ?? 0)) {
          darkColor = entry;
        }
      } else if (count > (lightColor?.value ?? 0)) {
        lightColor = entry;
      }
    }

    // If there is only single color, it is reported as both dark and light.
    return _ContrastReport._(
      lightColor?.key ?? darkColor!.key,
      darkColor?.key ?? lightColor!.key,
    );
  }

  const _ContrastReport._(this.lightColor, this.darkColor);

  /// The most frequently occurring light color. Uses [Colors.transparent] if
  /// the rectangle is empty.
  final Color lightColor;

  /// The most frequently occurring dark color. Uses [Colors.transparent] if
  /// the rectangle is empty.
  final Color darkColor;

  /// Computes the contrast ratio as defined by the WCAG.
  ///
  /// Source: https://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html
  double contrastRatio() => (lightColor.computeLuminance() + 0.05) / (darkColor.computeLuminance() + 0.05);
}

/// Gives the color histogram of all pixels inside a given rectangle on the
/// screen.
///
/// Given a [ByteData] object [data], which stores the color of each pixel
/// in row-first order, where each pixel is given in 4 bytes in RGBA order,
/// and [paintBounds], the rectangle, and [width] and [height],
//  the dimensions of the [ByteData] returns color histogram.
Map<Color, int> _colorsWithinRect(
    ByteData data,
    Rect paintBounds,
    int width,
    int height,
) {
  final Rect truePaintBounds = paintBounds.intersect(Rect.fromLTWH(0.0, 0.0, width.toDouble(), height.toDouble()));

  final int leftX = truePaintBounds.left.floor();
  final int rightX = truePaintBounds.right.ceil();
  final int topY = truePaintBounds.top.floor();
  final int bottomY = truePaintBounds.bottom.ceil();

  final Map<int, int> rgbaToCount = <int, int>{};

  int _getPixel(ByteData data, int x, int y) {
    final int offset = (y * width + x) * 4;
    return data.getUint32(offset);
  }

  for (int x = leftX; x < rightX; x++) {
    for (int y = topY; y < bottomY; y++) {
      rgbaToCount.update(
        _getPixel(data, x, y),
        (int count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  return rgbaToCount.map<Color, int>((int rgba, int count) {
    final int argb =  (rgba << 24) | (rgba >> 8) & 0xFFFFFFFF;
    return MapEntry<Color, int>(Color(argb), count);
  });
}

/// A guideline which requires tappable semantic nodes a minimum size of
/// 48 by 48.
///
/// See also:
///
///  * [Android tap target guidelines](https://support.google.com/accessibility/android/answer/7101858?hl=en).
const AccessibilityGuideline androidTapTargetGuideline = MinimumTapTargetGuideline(
  size: Size(48.0, 48.0),
  link: 'https://support.google.com/accessibility/android/answer/7101858?hl=en',
);

/// A guideline which requires tappable semantic nodes a minimum size of
/// 44 by 44.
///
/// See also:
///
///   * [iOS human interface guidelines](https://developer.apple.com/design/human-interface-guidelines/ios/visual-design/adaptivity-and-layout/).
const AccessibilityGuideline iOSTapTargetGuideline = MinimumTapTargetGuideline(
  size: Size(44.0, 44.0),
  link: 'https://developer.apple.com/design/human-interface-guidelines/ios/visual-design/adaptivity-and-layout/',
);

/// A guideline which requires text contrast to meet minimum values.
///
/// This guideline traverses the semantics tree looking for nodes with values or
/// labels that corresponds to a Text or Editable text widget. Given the
/// background pixels for the area around this widget, it performs a very naive
/// partitioning of the colors into "light" and "dark" and then chooses the most
/// frequently occurring color in each partition as a representative of the
/// foreground and background colors. The contrast ratio is calculated from
/// these colors according to the [WCAG](https://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html#contrast-ratiodef)
const AccessibilityGuideline textContrastGuideline = MinimumTextContrastGuideline();

/// A guideline which enforces that all nodes with a tap or long press action
/// also have a label.
const AccessibilityGuideline labeledTapTargetGuideline = LabeledTapTargetGuideline._();
