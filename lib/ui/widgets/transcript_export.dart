/// Getting the bytes off the phone, from wherever the failure happened.
///
/// Lives in its own widget because the place somebody needs it most is the
/// connect screen, which is not inside the shell that holds Settings. A failed
/// connection is precisely the session whose traffic explains something, and it
/// was the one session whose export button could not be reached: Settings sits
/// behind a successful connect, and the export read the transcript off a client
/// the teardown had already discarded.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../obd/transcript_store.dart';

import '../../core/theme/app_theme.dart';
import 'panel.dart';
import '../../state/obd_session.dart';
import '../../state/app_share_entry_controller.dart';
import '../../state/app_share_coordinator.dart';
import '../../state/transcript_store_runtime.dart';

/// How big a stored recording is, in a unit that does not read as "empty".
///
/// `bytes / 1024` rounded to zero decimals renders anything under 512 bytes as
/// `0 KB`, and a failed handshake — the reset, the timeout, the step it died on
/// — is a few hundred bytes. That is the most diagnostic recording this app
/// produces, and it was the one being offered as nothing. Nobody exports a file
/// the app has just called empty.
String formatTranscriptSize(int bytes) =>
    bytes < 1024 ? '$bytes 位元組' : '${(bytes / 1024).round()} KB';

/// Writes the transcript to a file and hands it to the share sheet.
///
/// A file rather than a text share: these run to hundreds of kilobytes and
/// every messaging app truncates a long string. The name carries the timestamp
/// so two exports from one afternoon do not overwrite each other.
Future<String?> exportTranscript(
  WidgetRef ref, {
  required bool withHex,
  Rect? sharePositionOrigin,
}) async {
  final session = ref.read(obdSessionProvider.notifier);
  // One read, so the heading and the bytes are from the same session.
  //
  // Reading them separately put an await between them — the temporary
  // directory — and a connection begun in that gap relabelled the old
  // session's bytes with the new session's adapter and protocol.
  final record = session.exportableRecord;
  if (record == null) return '沒有可匯出的紀錄。';
  try {
    final outcome = await ref
        .read(appShareEntryControllerProvider)
        .shareRawTranscript(
          transcript: record.transcript,
          header: record.header,
          withHex: withHex,
          subjectAt: DateTime.now(),
          sharePositionOrigin: sharePositionOrigin,
        );
    return outcome.userFacingError;
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
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      final error = await exportTranscript(
        ref,
        withHex: withHex,
        sharePositionOrigin: origin,
      );
      if (error == null || !context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!compact) ...[
          Text(
            '這次連線會保留開頭握手與最新的原始往返資料；'
            '長時間連線若省略中段，檔案會明確標出。'
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
  return ref.watch(managedTranscriptStoreProvider).load();
});

/// Hands a recovered recording to the share sheet.
///
/// Separate from [exportTranscript] because there is no session to read: the
/// bytes came off disk, written by an app that is no longer running. That is
/// the case this exists for — Android killed it, or the phone died, and the
/// only copy is the one that was saved on the way out.
///
/// [displayed] is the snapshot currently shown in the panel. Export refuses
/// when `last-session.log` no longer matches it, so a later periodic snapshot
/// cannot be shared under the previous-connection label.
Future<String?> exportRecoveredTranscript(
  WidgetRef ref,
  StoredTranscript displayed, {
  Rect? sharePositionOrigin,
}) async {
  try {
    final store = ref.read(managedTranscriptStoreProvider);
    final outcome = await ref
        .read(appShareEntryControllerProvider)
        .shareRecoveredTranscript(
          store: store,
          expected: displayed,
          sharePositionOrigin: sharePositionOrigin,
        );
    if (outcome.error == ShareError.storageFailure) {
      // openStreaming returned null because the file changed or vanished.
      ref.invalidate(recoveredTranscriptProvider);
      return '上一次連線的紀錄已更新，請再確認。';
    }
    return outcome.userFacingError;
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
              '${formatTranscriptSize(stored.bytes)}。'
              'App 被系統關掉或手機沒電時，紀錄還是留下來了。',
              style: context.texts.bodySmall,
            ),
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final box = context.findRenderObject() as RenderBox?;
                    final origin = box == null
                        ? null
                        : box.localToGlobal(Offset.zero) & box.size;
                    final error = await exportRecoveredTranscript(
                      ref,
                      stored,
                      sharePositionOrigin: origin,
                    );
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
                    final outcome = await ref
                        .read(managedTranscriptStoreProvider)
                        .clear(expected: stored);
                    if (outcome.succeeded) {
                      ref.invalidate(recoveredTranscriptProvider);
                    } else if (context.mounted) {
                      if (outcome.error ==
                          TranscriptMutationError.identityChanged) {
                        ref.invalidate(recoveredTranscriptProvider);
                      }
                      final message = switch (outcome.error) {
                        TranscriptMutationError.artifactBusy => '另一個檔案作業尚未完成。',
                        TranscriptMutationError.policyDenied ||
                        TranscriptMutationError.safetyChanged =>
                          '目前車速或連線狀態不允許刪除紀錄。',
                        TranscriptMutationError.identityChanged =>
                          '上一次連線的紀錄已更新，請再確認。',
                        TranscriptMutationError.storageFailure =>
                          '無法刪除上一次連線的紀錄。',
                        null => '',
                      };
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(message)));
                    }
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
