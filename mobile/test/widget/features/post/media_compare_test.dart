import 'dart:io';

import 'package:aside/core/media/film_filters.dart';
import 'package:aside/core/media/media_transform.dart';
import 'package:aside/features/post/media_edit_sheet.dart';
import 'package:aside/widgets/filtered_image.dart';
import 'package:aside/widgets/hold_to_compare.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  testWidgets('comparison works inside the photo editor without changing edits',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('aside-compare-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final image =
        File('assets/grain.png').copySync('${directory.path}/photo.png');
    var changed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showMediaEditSheet(
                    context,
                    photos: [XFile(image.path)],
                    photoMediaIndices: const [0],
                    initialIndex: 0,
                    filterFor: (_) => FilmFilters.slate,
                    transformFor: (_) =>
                        MediaTransform(rotation: 0.1, scale: 1.2),
                    onFilterChanged: (_, __) => changed++,
                    onTransformChanged: (_, __) => changed++,
                  ),
                  child: const Text('Edit photo'),
                ),
              )),
    ));
    await tester.tap(find.text('Edit photo'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();
    final preview = find.descendant(
      of: find.byType(HoldToCompare),
      matching: find.byType(FilteredImage),
    );
    expect(tester.widget<FilteredImage>(preview).filter.id, 'slate');
    final priorChanges = changed;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToCompare)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<FilteredImage>(preview).filter.isNone, true);
    await gesture.up();
    await tester.pump();
    expect(tester.widget<FilteredImage>(preview).filter.id, 'slate');
    expect(changed, priorChanges);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
