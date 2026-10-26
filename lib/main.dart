import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

void main() {
  runApp(const PresetTranslatorApp());
}

class PresetTranslatorApp extends StatelessWidget {
  const PresetTranslatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dịch Tên Preset',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardColor: const Color(0xFF1E1E1E),
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Color(0xFF4CAF50),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class FileRenameItem {
  final File file;
  final String oldName;
  String newName;
  bool selected;
  bool renamed;

  FileRenameItem({
    required this.file,
    required this.oldName,
    required this.newName,
    this.selected = true,
    this.renamed = false,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _promptCtrl = TextEditingController(
    text: 'Dịch tên các file preset màu ảnh sang tiếng Việt ngắn gọn, tự nhiên, đúng thuật ngữ nhiếp ảnh (ví dụ: Nhật hệ, Hồng Kông cổ điển, Trong trẻo, Phim nhựa, Đen vàng, Lạnh...). Giữ nguyên các con số thứ tự và phần mở rộng file (.xmp, .dng, .cube...).',
  );

  String _selectedMode = 'ai'; // 'ai' hoặc 'offline'
  String? _selectedDirPath;
  List<FileRenameItem> _items = [];
  bool _isLoading = false;
  String _statusMessage = 'Hãy cấp quyền bộ nhớ và chọn thư mục chứa Preset.';

  // Từ điển Offline chuyên cho Preset màu ảnh Trung - Anh
  final Map<String, String> _offlineDict = {
    '日系': 'Nhật hệ', '港风': 'Hồng Kông', '复古': 'Cổ điển',
    '胶片': 'Màu Phim', '清透': 'Trong trẻo', '通透': 'Trong sáng',
    '冷色调': 'Tông lạnh', '暖色调': 'Tông ấm', '暗调': 'Tông trầm',
    '黑金': 'Đen Vàng', '青橙': 'Xanh Cam', '莫兰迪': 'Morandi',
    '电影': 'Điện ảnh', '人像': 'Chân dung', '风景': 'Phong cảnh',
    '夜景': 'Cảnh đêm', '街拍': 'Đường phố', '森系': 'Rừng cây',
    '奶油': 'Kem mịn', '高级灰': 'Xám sang trọng', '情绪': 'Tâm trạng',
    '富士': 'Fujifilm', '柯达': 'Kodak', '黑白': 'Đen trắng',
    '美式': 'Phong cách Mỹ', '法式': 'Phong cách Pháp', '秋日': 'Mùa thu',
    '夏日': 'Mùa hè', '冬日': 'Mùa đông', '春日': 'Mùa xuân',
    '夕阳': 'Hoàng hôn', '落日': 'Hoàng hôn', '海边': 'Bờ biển',
    '质感': 'Chất cảm', '纪实': 'Phóng sự', '复古胶片': 'Phim cổ điển',
    '网红': 'Trend', '甜美': 'Ngọt ngào', '清新': 'Tươi mới',
    '婚礼': 'Ảnh cưới', '旅拍': 'Du lịch', '室内': 'Trong nhà',
  };

  @override
  void initState() {
    super.initState();
    _loadSavedConfig();
  }

  Future<void> _loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyCtrl.text = prefs.getString('gemini_api_key') ?? '';
      _selectedMode = prefs.getString('translate_mode') ?? 'ai';
    });
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', _apiKeyCtrl.text.trim());
    await prefs.setString('translate_mode', _selectedMode);
  }

  Future<bool> _requestStoragePermission() async {
    if (Platform.isAndroid) {
      if (await Permission.manageExternalStorage.isGranted) {
        return true;
      }
      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;

      final storageStatus = await Permission.storage.request();
      return storageStatus.isGranted;
    }
    return true;
  }

  Future<void> _pickDirectory() async {
    final hasPerm = await _requestStoragePermission();
    if (!hasPerm) {
      setState(() => _statusMessage = 'Cần cấp quyền Quản lý tất cả tệp để đổi tên trực tiếp!');
      openAppSettings();
      return;
    }

    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory == null) return;

    final dir = Directory(selectedDirectory);
    final List<FileSystemEntity> entities = dir.listSync(recursive: false);
    final List<FileRenameItem> loaded = [];

    for (var entity in entities) {
      if (entity is File) {
        final name = p.basename(entity.path);
        if (!name.startsWith('.')) {
          loaded.add(FileRenameItem(
            file: entity,
            oldName: name,
            newName: name,
          ));
        }
      }
    }

    loaded.sort((a, b) => a.oldName.compareTo(b.oldName));

    setState(() {
      _selectedDirPath = selectedDirectory;
      _items = loaded;
      _statusMessage = 'Đã tải ${loaded.length} file từ thư mục.';
    });
  }

  String _translateOfflineSingle(String filename) {
    final ext = p.extension(filename);
    String base = p.basenameWithoutExtension(filename);
    _offlineDict.forEach((key, val) {
      base = base.replaceAll(key, ' $val ');
    });
    base = base.replaceAll(RegExp(r'\s+'), ' ').trim();
    return '$base$ext';
  }

  Future<void> _translateBatch() async {
    if (_items.isEmpty) return;
    await _saveConfig();

    setState(() {
      _isLoading = true;
      _statusMessage = 'Đang dịch tên ${ _items.length } file...';
    });

    try {
      if (_selectedMode == 'offline') {
        setState(() {
          for (var item in _items) {
            if (item.selected) {
              item.newName = _translateOfflineSingle(item.oldName);
            }
          }
          _statusMessage = 'Đã dịch xong (Chế độ Từ điển Offline). Kiểm tra trước khi lưu!';
        });
      } else {
        final apiKey = _apiKeyCtrl.text.trim();
        if (apiKey.isEmpty) {
          throw Exception('Vui lòng nhập Gemini API Key hoặc chọn chế độ Offline!');
        }

        // Chia theo lô 50 file để tránh quá tải token
        const int batchSize = 50;
        for (int i = 0; i < _items.length; i += batchSize) {
          final end = (i + batchSize < _items.length) ? i + batchSize : _items.length;
          final chunk = _items.sublist(i, end);
          final originalNames = chunk.map((e) => e.oldName).toList();

          final url = Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
          );

          final prompt = '${_promptCtrl.text}\n'
              'CHỈ TRẢ VỀ DUY NHẤT 1 MẢNG JSON (JSON Array) chứa chuỗi tên mới tương ứng đúng thứ tự và đúng số lượng (${originalNames.length} phần tử). Không thêm bất kỳ giải thích nào.\n'
              'Danh sách tên gốc:\n${jsonEncode(originalNames)}';

          final response = await http.post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': prompt}
                  ]
                }
              ],
              'generationConfig': {'responseMimeType': 'application/json'}
            }),
          );

          final body = jsonDecode(utf8.decode(response.bodyBytes));
          if (body['error'] != null) {
            throw Exception(body['error']['message']);
          }

          final rawText = body['candidates'][0]['content']['parts'][0]['text'];
          final List<dynamic> translatedList = jsonDecode(rawText);

          if (translatedList.length == chunk.length) {
            for (int j = 0; j < chunk.length; j++) {
              String cleanName = translatedList[j].toString().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
              chunk[j].newName = cleanName;
            }
          }
        }
        setState(() {
          _statusMessage = 'Đã dịch xong bằng AI! Bạn có thể sửa tay từng tên hoặc bấm Đổi Tên.';
        });
      }
    } catch (e) {
      setState(() => _statusMessage = 'Lỗi: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _applyRenameOnDisk() async {
    if (_items.isEmpty) return;
    int successCount = 0;

    setState(() => _isLoading = true);

    for (var item in _items) {
      if (item.selected && item.oldName != item.newName && !item.renamed) {
        try {
          final dirPath = p.dirname(item.file.path);
          final newPath = p.join(dirPath, item.newName);
          await item.file.rename(newPath);
          item.renamed = true;
          successCount++;
        } catch (_) {}
      }
    }

    setState(() {
      _isLoading = false;
      _statusMessage = 'Hoàn tất! Đã đổi tên trực tiếp $successCount file trong điện thoại.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dịch & Đổi Tên Preset', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Khung cấu hình
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('Chế độ: ', style: TextStyle(color: Colors.grey)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButton<String>(
                            value: _selectedMode,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: 'ai', child: Text('Gemini AI (Chuẩn ngữ cảnh màu ảnh)')),
                              DropdownMenuItem(value: 'offline', child: Text('Từ điển Offline (Không cần mạng)')),
                            ],
                            onChanged: (val) {
                              if (val != null) setState(() => _selectedMode = val);
                            },
                          ),
                        ),
                      ],
                    ),
                    if (_selectedMode == 'ai') ...[
                      const SizedBox(height: 6),
                      TextField(
                        controller: _apiKeyCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Gemini API Key',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _promptCtrl,
                        maxLines: 2,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          labelText: 'Quy tắc dịch (Tuỳ chỉnh)',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isLoading ? null : _pickDirectory,
                            icon: const Icon(Icons.folder_open, size: 18),
                            label: const Text('1. Chọn Thư Mục'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.black,
                            ),
                            onPressed: (_isLoading || _items.isEmpty) ? null : _translateBatch,
                            icon: const Icon(Icons.translate, size: 18),
                            label: const Text('2. Dịch Tên'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: (_isLoading || _items.isEmpty) ? null : _applyRenameOnDisk,
                        icon: const Icon(Icons.check_circle_outline, size: 18),
                        label: const Text('3. Áp Dụng Đổi Tên Trực Tiếp Vào Máy'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Text(
                _statusMessage,
                style: const TextStyle(fontSize: 12, color: Colors.amberAccent),
              ),
            ),

            if (_isLoading) const LinearProgressIndicator(),

            // Danh sách file
            Expanded(
              child: _items.isEmpty
                  ? const Center(
                      child: Text(
                        'Chưa có file nào.\nBấm "1. Chọn Thư Mục" để quét các file preset (.dng, .xmp, .cube...)',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          leading: Checkbox(
                            value: item.selected,
                            onChanged: (v) => setState(() => item.selected = v ?? true),
                          ),
                          title: Text(
                            'Gốc: ${item.oldName}',
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: TextFormField(
                              key: ValueKey('${item.oldName}_${item.newName}'),
                              initialValue: item.newName,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: item.renamed ? Colors.cyanAccent : const Color(0xFF81C784),
                              ),
                              decoration: const InputDecoration(
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (val) => item.newName = val,
                            ),
                          ),
                          trailing: item.renamed
                              ? const Icon(Icons.done_all, color: Colors.cyanAccent, size: 18)
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
