import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';

import '../data/firestore_chat_repository.dart';
import '../data/presence_service.dart';
import '../data/quick_replies_service.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'lead_sheet.dart';
import 'vip_client_sheet.dart';

/// Список чатов из Firestore (firebase-режим миграции).
class FirebaseConversationsScreen extends ConsumerWidget {
  const FirebaseConversationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF0E1519), Color(0xFF0B1013)] : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(children: [
                  const Text('Чаты', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                  const SizedBox(width: 8),
                  const _FbBadge(),
                  const Spacer(),
                  const _FbOnlineBadge(),
                ]),
              ),
              Expanded(
                child: ref.watch(firebaseConversationsProvider).when(
                      loading: () => const Center(child: CircularProgressIndicator()),
                      error: (e, _) => _msg(Icons.cloud_off, 'Ошибка', '$e'),
                      data: (items) {
                        if (items.isEmpty) return _msg(Icons.forum_outlined, 'Пока нет чатов', 'Входящие появятся здесь');
                        return ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          itemCount: items.length,
                          itemBuilder: (context, i) => _tile(context, items[i], dark),
                        );
                      },
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, FsConversation c, bool dark) {
    final unread = c.unreadCount > 0;
    final time = c.lastMessageAt != null ? DateFormat('HH:mm').format(c.lastMessageAt!) : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: dark ? const Color(0xFF1B242B) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FirebaseChatScreen(conversation: c))),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 50, height: 50,
                decoration: const BoxDecoration(shape: BoxShape.circle),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(flagAsset(c.phone ?? c.id), fit: BoxFit.cover),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: unread ? FontWeight.w700 : FontWeight.w600))),
                    Text(time, style: TextStyle(fontSize: 12, color: unread ? AppColors.brand : context.semantic.textSecondary)),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Expanded(child: Text(c.preview ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: context.semantic.textSecondary))),
                    if (unread) Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(gradient: brandGradient, borderRadius: BorderRadius.circular(11)),
                      child: Text('${c.unreadCount}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _msg(IconData i, String t, String s) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(i, size: 54, color: AppColors.brand.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(s, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ]),
        ),
      );
}

class _FbBadge extends StatelessWidget {
  const _FbBadge();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
        child: const Text('Firebase', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFC97A0A))),
      );
}

/// «N в сети» (presence из Firestore). Тап — список имён.
class _FbOnlineBadge extends ConsumerWidget {
  const _FbOnlineBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return StreamBuilder<List<PresenceUser>>(
      stream: ref.watch(firebasePresenceServiceProvider).watch(),
      builder: (context, snap) {
        final online = snap.data ?? const [];
        if (online.isEmpty) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () => _showList(context, ref, online),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF1B242B) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF2ECC71), shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text('${online.length} в сети', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
          ),
        );
      },
    );
  }

  void _showList(BuildContext context, WidgetRef ref, List<PresenceUser> online) {
    final me = ref.read(appConfigProvider).userId;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(children: [
              Container(width: 9, height: 9, decoration: const BoxDecoration(color: Color(0xFF2ECC71), shape: BoxShape.circle)),
              const SizedBox(width: 9),
              Text('В системе сейчас — ${online.length}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
          ),
          const Divider(height: 1),
          for (final u in online)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.brand.withValues(alpha: 0.15),
                child: Text((u.name.isNotEmpty ? u.name[0] : '?').toUpperCase(), style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w700)),
              ),
              title: Text(u.name.isEmpty ? 'Менеджер' : u.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: u.uid == me ? const Text('вы', style: TextStyle(color: AppColors.brand, fontWeight: FontWeight.w700)) : null,
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// Переписка одного чата из Firestore + отправка через Cloud Function.
class FirebaseChatScreen extends ConsumerStatefulWidget {
  const FirebaseChatScreen({super.key, required this.conversation});
  final FsConversation conversation;

  @override
  ConsumerState<FirebaseChatScreen> createState() => _FirebaseChatScreenState();
}

class _FirebaseChatScreenState extends ConsumerState<FirebaseChatScreen> {
  final _input = TextEditingController();
  bool _sending = false;
  bool _hasText = false;

  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  int _recSeconds = 0;
  Timer? _recTimer;
  String? _recPath;

  @override
  void initState() {
    super.initState();
    _input.addListener(() {
      final has = _input.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    ref.read(firestoreChatRepositoryProvider).markRead(widget.conversation.id).catchError((_) {});
  }

  @override
  void dispose() {
    _recTimer?.cancel();
    _recorder.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _startRec() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нет доступа к микрофону')));
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      _recPath = path;
      setState(() {
        _recording = true;
        _recSeconds = 0;
      });
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recSeconds++);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Запись не началась: $e')));
    }
  }

  Future<void> _stopRecAndSend() async {
    _recTimer?.cancel();
    final tooShort = _recSeconds < 1;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {}
    setState(() => _recording = false);
    if (path == null || tooShort) {
      if (tooShort && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Слишком коротко')));
      return;
    }
    setState(() => _sending = true);
    try {
      final bytes = await File(path).readAsBytes();
      await ref.read(firestoreChatRepositoryProvider).sendMedia(
            phone: widget.conversation.phone ?? widget.conversation.id,
            bytes: bytes,
            fileName: 'voice.m4a',
            contentType: 'audio/mp4',
            kind: 'audio',
            name: widget.conversation.name,
          );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Голосовое не отправлено: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _cancelRec() async {
    _recTimer?.cancel();
    try {
      await _recorder.stop();
      if (_recPath != null) {
        final f = File(_recPath!);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    if (mounted) setState(() => _recording = false);
  }

  Future<void> _pickAndSend() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Фото из галереи'), onTap: () => Navigator.pop(s, 'gallery')),
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Камера'), onTap: () => Navigator.pop(s, 'camera')),
          ListTile(leading: const Icon(Icons.attach_file), title: const Text('Файл'), onTap: () => Navigator.pop(s, 'file')),
        ]),
      ),
    );
    debugPrint('[FB-PICK] выбор: $choice');
    if (choice == null) return;

    List<int>? bytes;
    String? fileName;
    String? mime;
    String kind = 'document';
    try {
      if (choice == 'gallery' || choice == 'camera') {
        final x = await ImagePicker().pickImage(source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery, imageQuality: 85);
        if (x == null) return;
        bytes = await x.readAsBytes();
        fileName = x.name;
        mime = x.mimeType ?? 'image/jpeg';
        kind = 'image';
      } else {
        final res = await FilePicker.platform.pickFiles(withData: true);
        final f = res?.files.isNotEmpty == true ? res!.files.first : null;
        if (f == null || f.bytes == null) return;
        bytes = f.bytes!;
        fileName = f.name;
        mime = 'application/octet-stream';
        kind = 'document';
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось выбрать: $e')));
      return;
    }

    debugPrint('[FB-PICK] файл: $fileName ($mime), ${bytes.length} байт, kind=$kind');
    setState(() => _sending = true);
    try {
      await ref.read(firestoreChatRepositoryProvider).sendMedia(
            phone: widget.conversation.phone ?? widget.conversation.id,
            bytes: bytes,
            fileName: fileName,
            contentType: mime,
            kind: kind,
            name: widget.conversation.name,
          );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Медиа отправлено')));
    } catch (e) {
      debugPrint('[FB-PICK] ❌ отправка медиа: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    try {
      await ref.read(firestoreChatRepositoryProvider).sendText(
            phone: widget.conversation.phone ?? widget.conversation.id,
            text: text,
            name: widget.conversation.name,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
        _input.text = text;
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final phone = widget.conversation.phone ?? widget.conversation.id;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: const BoxDecoration(shape: BoxShape.circle),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(flagAsset(phone), fit: BoxFit.cover),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(widget.conversation.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
        ]),
        actions: [
          _pill('ЛИД', Icons.bolt_rounded, const [Color(0xFF20C9B6), Color(0xFF0E8F82)], const Color(0xFF13B0A0),
              () => LeadSheet.show(context, name: widget.conversation.name, phone: phone)),
          _pill('VIP', Icons.workspace_premium_rounded, const [Color(0xFFFF5566), Color(0xFFD11E31)], const Color(0xFFE23744),
              () => VipClientSheet.show(context, name: widget.conversation.name, phone: phone)),
          const SizedBox(width: 8),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF0E1519), Color(0xFF0B1013)] : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: Column(children: [
          Expanded(
            child: ref.watch(firebaseMessagesProvider(widget.conversation.id)).when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('Ошибка: $e')),
                  data: (msgs) => ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    itemCount: msgs.length,
                    itemBuilder: (context, i) => _bubble(msgs[msgs.length - 1 - i], dark),
                  ),
                ),
          ),
          _composer(dark),
        ]),
      ),
    );
  }

  Widget _pill(String label, IconData icon, List<Color> colors, Color glow, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: colors),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: glow.withValues(alpha: 0.32), blurRadius: 7, offset: const Offset(0, 2))],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: Colors.white, size: 14),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5, letterSpacing: 0.4)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _bubble(FsMessage m, bool dark) {
    final out = m.isOutbound;
    final hasMedia = m.media != null && m.media!.isNotEmpty;
    final isImage = m.type == 'image' && hasMedia;
    final hasText = m.text != null && m.text!.isNotEmpty;
    final body = hasText ? m.text! : (!hasMedia && m.type != 'text' ? '[${m.type}]' : '');
    final time = m.createdAt != null ? DateFormat('HH:mm').format(m.createdAt!) : '';
    final textColor = out ? Colors.white : (dark ? const Color(0xFFE9EEF0) : const Color(0xFF0E1B22));
    final metaColor = out ? Colors.white.withValues(alpha: 0.85) : (dark ? Colors.white54 : Colors.black38);
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: EdgeInsets.fromLTRB(isImage ? 4 : 13, isImage ? 4 : 8, isImage ? 4 : 11, isImage ? 6 : 7),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
        decoration: BoxDecoration(
          gradient: out ? brandGradient : null,
          color: out ? null : (dark ? const Color(0xFF1B242B) : Colors.white),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(out ? 18 : 6),
            bottomRight: Radius.circular(out ? 6 : 18),
          ),
          boxShadow: [BoxShadow(color: out ? AppColors.brand.withValues(alpha: 0.22) : Colors.black.withValues(alpha: dark ? 0.25 : 0.05), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          if (isImage) _mediaImage(m.media!),
          if (hasMedia && !isImage && m.type == 'audio') _FbVoicePlayer(url: m.media!, onGradient: out),
          if (hasMedia && !isImage && m.type != 'audio') _mediaCard(m, out),
          if (body.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: hasMedia ? 6 : 0, left: isImage ? 8 : 0, right: isImage ? 8 : 0),
              child: Text(body, style: TextStyle(color: textColor, fontSize: 15.5, height: 1.3)),
            ),
          Padding(
            padding: EdgeInsets.only(top: 2, right: isImage ? 8 : 0),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(time, style: TextStyle(fontSize: 10.5, color: metaColor)),
            if (out) ...[
              const SizedBox(width: 3),
              Icon(
                m.status == 'read' ? Icons.done_all : (m.status == 'delivered' ? Icons.done_all : Icons.check),
                size: 13,
                color: m.status == 'read' ? const Color(0xFFBEEFFF) : metaColor,
              ),
            ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _mediaImage(String url) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 258, maxHeight: 320, minWidth: 160, minHeight: 110),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          loadingBuilder: (c, w, p) => p == null ? w : Container(width: 200, height: 150, color: Colors.black12, alignment: Alignment.center, child: const CircularProgressIndicator(strokeWidth: 2)),
          errorBuilder: (_, _, _) => Container(width: 200, height: 120, color: Colors.black12, alignment: Alignment.center, child: const Icon(Icons.broken_image_outlined, color: Colors.grey)),
        ),
      ),
    );
  }

  Widget _mediaCard(FsMessage m, bool out) {
    final fg = out ? Colors.white : AppColors.brand;
    final sub = out ? Colors.white70 : Colors.grey;
    final icon = switch (m.type) {
      'audio' => Icons.mic_rounded,
      'video' => Icons.play_circle_outline,
      _ => Icons.description_outlined,
    };
    final label = switch (m.type) {
      'audio' => 'Голосовое / аудио',
      'video' => 'Видео',
      _ => 'Файл',
    };
    return InkWell(
      onTap: m.media != null ? () => launchUrl(Uri.parse(m.media!), mode: LaunchMode.externalApplication) : null,
      child: SizedBox(
        width: 226,
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: (out ? Colors.white : AppColors.brand).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, color: fg, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: TextStyle(color: out ? Colors.white : const Color(0xFF10202A), fontWeight: FontWeight.w600, fontSize: 14)),
              Text('Открыть', style: TextStyle(fontSize: 11.5, color: sub)),
            ]),
          ),
          Icon(Icons.download_rounded, size: 20, color: fg),
        ]),
      ),
    );
  }

  Widget _composer(bool dark) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        color: dark ? const Color(0xFF12191E) : Colors.white,
        child: _recording ? _recBar() : _inputBar(dark),
      ),
    );
  }

  Widget _recBar() {
    final m = (_recSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_recSeconds % 60).toString().padLeft(2, '0');
    return Row(children: [
      IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: _cancelRec),
      Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
      const SizedBox(width: 8),
      Text('$m:$s', style: const TextStyle(fontWeight: FontWeight.w600)),
      const Spacer(),
      const Text('Запись…', style: TextStyle(color: Colors.grey)),
      const SizedBox(width: 10),
      GestureDetector(
        onTap: _sending ? null : _stopRecAndSend,
        child: Container(
          width: 46, height: 46,
          decoration: const BoxDecoration(color: AppColors.brand, shape: BoxShape.circle),
          child: const Icon(Icons.send_rounded, color: Colors.white),
        ),
      ),
    ]);
  }

  void _openQuickReplies() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _QuickRepliesSheet(onPick: (text) {
        _input.text = text;
        _input.selection = TextSelection.fromPosition(TextPosition(offset: text.length));
        setState(() => _hasText = text.trim().isNotEmpty);
      }),
    );
  }

  Widget _inputBar(bool dark) {
    return Row(children: [
      IconButton(
        icon: const Icon(Icons.bolt_rounded, color: AppColors.brand),
        tooltip: 'Быстрые ответы',
        onPressed: _sending ? null : _openQuickReplies,
      ),
      IconButton(
        icon: const Icon(Icons.add_circle_outline_rounded, color: AppColors.brand),
        onPressed: _sending ? null : _pickAndSend,
      ),
      Expanded(
        child: TextField(
          controller: _input,
          minLines: 1, maxLines: 5,
          decoration: InputDecoration(
            hintText: 'Сообщение…',
            filled: true,
            fillColor: dark ? const Color(0xFF232E36) : const Color(0xFFEDF2F2),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
        ),
      ),
      const SizedBox(width: 8),
      GestureDetector(
        onTap: _sending ? null : (_hasText ? _send : _startRec),
        child: Container(
          width: 46, height: 46,
          decoration: const BoxDecoration(color: AppColors.brand, shape: BoxShape.circle),
          child: _sending
              ? const Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Icon(_hasText ? Icons.send_rounded : Icons.mic_rounded, color: Colors.white),
        ),
      ),
    ]);
  }
}

/// Компактный проигрыватель голосового в firebase-режиме (just_audio).
class _FbVoicePlayer extends StatefulWidget {
  const _FbVoicePlayer({required this.url, required this.onGradient});
  final String url;
  final bool onGradient;

  @override
  State<_FbVoicePlayer> createState() => _FbVoicePlayerState();
}

class _FbVoicePlayerState extends State<_FbVoicePlayer> {
  final _player = AudioPlayer();
  bool _prepared = false;
  bool _loading = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!_prepared) {
      setState(() => _loading = true);
      try {
        await _player.setUrl(widget.url);
        _prepared = true;
      } catch (_) {
        if (mounted) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось воспроизвести')));
        }
        return;
      }
      if (mounted) setState(() => _loading = false);
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) await _player.seek(Duration.zero);
      _player.play();
    }
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final og = widget.onGradient;
    final circleBg = og ? Colors.white : AppColors.brand;
    final circleFg = og ? AppColors.brand : Colors.white;
    final active = og ? Colors.white : AppColors.brand;
    final muted = og ? Colors.white.withValues(alpha: 0.35) : AppColors.brand.withValues(alpha: 0.3);
    final timeColor = og ? Colors.white.withValues(alpha: 0.85) : Colors.grey.shade600;

    return SizedBox(
      width: 210,
      child: Row(children: [
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 38, height: 38,
            decoration: BoxDecoration(color: circleBg, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: _loading
                ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: circleFg))
                : Icon(_player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: circleFg, size: 22),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: StreamBuilder<Duration>(
            stream: _player.positionStream,
            builder: (context, snap) {
              final pos = snap.data ?? Duration.zero;
              final dur = _player.duration ?? Duration.zero;
              final progress = dur.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
              return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: progress, minHeight: 4, backgroundColor: muted, color: active),
                ),
                const SizedBox(height: 5),
                Text(_player.playing || pos > Duration.zero ? _fmt(pos) : _fmt(dur), style: TextStyle(fontSize: 11, color: timeColor)),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

/// Лист быстрых ответов: выбрать (вставится в поле), добавить, удалить.
class _QuickRepliesSheet extends ConsumerStatefulWidget {
  const _QuickRepliesSheet({required this.onPick});
  final void Function(String text) onPick;

  @override
  ConsumerState<_QuickRepliesSheet> createState() => _QuickRepliesSheetState();
}

class _QuickRepliesSheetState extends ConsumerState<_QuickRepliesSheet> {
  Future<void> _openEditor({QuickReply? existing}) async {
    final titleC = TextEditingController(text: existing?.title ?? '');
    final textC = TextEditingController(text: existing?.text ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(existing == null ? 'Новый шаблон' : 'Редактировать'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: titleC,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Заголовок', hintText: 'напр. Приветствие'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: textC,
            minLines: 2, maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Основной текст', hintText: 'Текст, который вставится в сообщение'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok == true && textC.text.trim().isNotEmpty) {
      final svc = ref.read(quickRepliesServiceProvider);
      final title = titleC.text.trim().isEmpty ? textC.text.trim() : titleC.text.trim();
      try {
        if (existing == null) {
          await svc.add(title: title, text: textC.text.trim());
        } else {
          await svc.update(existing.id, title: title, text: textC.text.trim());
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
    titleC.dispose();
    textC.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF12191E) : const Color(0xFFF2F5F7),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(children: [
            const SizedBox(height: 10),
            Container(width: 42, height: 5, decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(3))),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(children: [
                Icon(Icons.bolt_rounded, color: AppColors.brand),
                SizedBox(width: 8),
                Text('Быстрые ответы', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ]),
            ),
            Expanded(
              child: ref.watch(quickRepliesProvider).when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('Ошибка: $e')),
                    data: (items) {
                      if (items.isEmpty) {
                        return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Пока нет шаблонов.\nНажмите «Добавить».', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))));
                      }
                      return ListView.builder(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final q = items[i];
                          return Dismissible(
                            key: ValueKey(q.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              decoration: BoxDecoration(color: Colors.red.shade400, borderRadius: BorderRadius.circular(14)),
                              child: const Icon(Icons.delete_outline, color: Colors.white),
                            ),
                            onDismissed: (_) => ref.read(quickRepliesServiceProvider).delete(q.id),
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              decoration: BoxDecoration(
                                color: dark ? const Color(0xFF1B242B) : Colors.white,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: ListTile(
                                title: Text(q.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                                subtitle: Text(q.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: dark ? Colors.white60 : Colors.black54)),
                                trailing: IconButton(icon: const Icon(Icons.edit_outlined, size: 19), onPressed: () => _openEditor(existing: q)),
                                onTap: () {
                                  widget.onPick(q.text);
                                  Navigator.of(context).pop();
                                },
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: SizedBox(
                  height: 50,
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.brand, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Добавить шаблон', style: TextStyle(fontWeight: FontWeight.w700)),
                    onPressed: () => _openEditor(),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
