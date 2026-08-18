/// Getting the bytes off the phone, from wherever the failure happened.
///
/// Lives in its own widget because the place somebody needs it most is the
/// connect screen, which is not inside the shell that holds Settings. A failed
/// connection is precisely the session whose traffic explains something, and it
/// was the one session whose export button could not be reached: Settings sits
/// behind a successful connect, and the export read the transcript off a client
/// the teardown had already discarded.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../obd/transcript_store.dart';

import '../../core/theme/app_theme.dart';
import 'panel.dart';
import '../../state/obd_session.dart';

/// Writes the transcript to a file and hands it to the share sheet.
///
/// A file rather than a text share: these run to hundreds of kilobytes and
/// every messaging app truncates a long string. The name carries the timestamp
/// so two exports from one afternoon do not overwrite each other.
Future<String?> exportTranscript(WidgetRef ref, {required bool withHex}) async {
  final session = ref.read(obdSessionProvider.notifier);
  // One read, so the heading and the bytes are from the same session.
  //
  // Reading them separately put an await between them — the temporary
  // directory — and a connection begun in that gap relabelled the old
  // session's bytes with the new session's adapter and protocol.
  final record = session.exportableRecord;
  if (record == null) return '沒有可匯出的紀錄。';
  final transcript = record.transcript;
  try {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/torque-obd-$stamp.txt');
    await file.writeAsBytes(transcript.encode(
      header: record.header,
      withHex: withHex,
    ));
    await SharePlus.instance.share(ShareParams(
      // Declared, not inferred.
      //
      // Without it Android is left to guess from the extension, and the guess
      // is not carried through every share target the same way: on a Galaxy
      // S25 the Quick Share **儲存** target answered 無法儲存文字，建議改為儲存
      // 連結 — it had taken the payload for a string. The sibling export a
      // file away has always named `text/csv`; this one had nothing.
      //
      // This is the one instruction `FIELD_GUIDE.md` gives for every situation
      // it cannot otherwise resolve, so the obvious way to keep the file has
      // to be the working one.
      files: [XFile(file.path, mimeType: 'text/plain')],
      subject: 'Telltale 傳輸紀錄 $stamp',
      fileNameOverrides: ['torque-obd-$stamp.txt'],
    ));
    return null;
  } on Object catch (e) {
    return '匯出失敗：$e';
  }
}

/// The two export buttons, with the explanation above them.
///
/// [compact] drops the explanation — used on the connect screen, where the
/// failure banner has already said what went wrong and the only thing left to
/// add is a way to carry the evidence away.
class TranscriptExportButtons extends ConsumerWidget {
  const TranscriptExportButtons({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched, not read: the buttons have to come alive the moment a failed
    // attempt leaves something behind.
    ref.watch(obdSessionProvider);
    final available = ref.read(obdSessionProvider.notifier).hasTranscript;

    Future<void> run(bool withHex) async {
      final error = await exportTranscript(ref, withHex: withHex);
      if (error == null || !context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!compact) ...[
          Text(
            '這次連線與轉接器之間往返的每一個位元組都會記錄下來。'
            '在車上遇到讀不到、判斷不出來的情況時，把紀錄匯出帶回來，'
            '比畫面上的一句訊息有用得多。',
            style: context.texts.bodySmall,
          ),
          const SizedBox(height: Spacing.md),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: available ? () => run(false) : null,
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('匯出紀錄'),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: available ? () => run(true) : null,
                icon: const Icon(Icons.data_object, size: 18),
                label: const Text('含十六進位'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The recording left behind by a previous run of the app.
///
/// Loaded once, because the answer only changes when a session ends and this
/// is read on a screen the user reaches between sessions.
final recoveredTranscriptProvider = FutureProvider<StoredTranscript?>((ref) {
  return TranscriptStore().load();
});

/// Hands a recovered recording to the share sheet.
///
/// Separate from [exportTranscript] because there is no session to read: the
/// bytes came off disk, written by an app that is no longer running. That is
/// the case this exists for — Android killed it, or the phone died, and the
/// only copy is the one that was saved on the way out.
Future<String?> exportRecoveredTranscript(StoredTranscript stored) async {
  try {
    final at = stored.savedAt;
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${at.year}${two(at.month)}${two(at.day)}'
        '-${two(at.hour)}${two(at.minute)}${two(at.second)}';
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/torque-obd-$stamp-recovered.txt');
    await file.writeAsString('${stored.header}${stored.body}');
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'text/plain')],
      subject: 'Telltale 傳輸紀錄（上一次連線）$stamp',
      fileNameOverrides: ['torque-obd-$stamp-recovered.txt'],
    ));
    return null;
  } on Object catch (e) {
    return '匯出失敗：$e';
  }
}

/// The panel offering a recording that outlived its app.
///
/// Shown only when there is one, and worded so it is obvious this is *not*
/// this session: somebody who has just reconnected and is looking at a working
/// car should not mistake it for the log they are about to make.
class RecoveredTranscriptPanel extends ConsumerWidget {
  const RecoveredTranscriptPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recovered = ref.watch(recoveredTranscriptProvider);
    final stored = recovered.asData?.value;
    if (stored == null) return const SizedBox.shrink();

    final at = stored.savedAt;
    String two(int v) => v.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('上一次連線的紀錄', style: context.texts.titleSmall),
            const SizedBox(height: Spacing.xs),
            Text(
              '${at.year}/${two(at.month)}/${two(at.day)} '
              '${two(at.hour)}:${two(at.minute)} 留下的，'
              '${(stored.bytes / 1024).toStringAsFixed(0)} KB。'
              'App 被系統關掉或手機沒電時，紀錄還是留下來了。',
              style: context.texts.bodySmall,
            ),
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final error = await exportRecoveredTranscript(stored);
                    if (error != null && context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(error)));
                    }
                  },
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('匯出'),
                ),
                const SizedBox(width: Spacing.sm),
                TextButton(
                  onPressed: () async {
                    await TranscriptStore().clear();
                    ref.invalidate(recoveredTranscriptProvider);
                  },
                  child: const Text('刪除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
