import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

// --- MODELS ---
enum NoteType { text, audio }

class NoteItem {
  final String id;
  final NoteType type;
  final String content;
  final String? audioPath;
  final DateTime createdAt;

  NoteItem({
    required this.id,
    required this.type,
    required this.content,
    this.audioPath,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type.index,
      'content': content,
      'audioPath': audioPath,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory NoteItem.fromMap(Map<String, dynamic> map) {
    return NoteItem(
      id: map['id'],
      type: NoteType.values[map['type']],
      content: map['content'],
      audioPath: map['audioPath'],
      createdAt: DateTime.parse(map['createdAt']),
    );
  }
}

// --- SERVICES ---
class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = p.join(documentsDirectory.path, 'ids_normal_notes.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) {
        return db.execute(
          'CREATE TABLE notes(id TEXT PRIMARY KEY, type INTEGER, content TEXT, audioPath TEXT, createdAt TEXT)',
        );
      },
    );
  }

  Future<void> insertNote(NoteItem note) async {
    final db = await database;
    await db.insert('notes', note.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<NoteItem>> getNotes() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('notes', orderBy: 'createdAt DESC');
    return List.generate(maps.length, (i) => NoteItem.fromMap(maps[i]));
  }

  Future<void> deleteNote(String id) async {
    final db = await database;
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }
}

class AudioHelper {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isRecording = false;

  Future<void> startRecording(String path) async {
    if (await _audioRecorder.hasPermission()) {
      await _audioRecorder.start(const RecordConfig(), path: path);
      _isRecording = true;
    }
  }

  Future<void> stopRecording() async {
    if (_isRecording) {
      await _audioRecorder.stop();
      _isRecording = false;
    }
  }

  Future<void> playAudio(String path) async {
    await _audioPlayer.play(DeviceFileSource(path));
  }

  void dispose() {
    _audioRecorder.dispose();
    _audioPlayer.dispose();
  }
}

// --- APP ENTRY ---
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IDSNormalApp());
}

class IDSNormalApp extends StatelessWidget {
  const IDSNormalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'IDS Note',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.cyanAccent,
          secondary: Colors.deepPurpleAccent,
        ),
        textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
      ),
      home: const NoteHomeScreen(),
    );
  }
}

class NoteHomeScreen extends StatefulWidget {
  const NoteHomeScreen({super.key});

  @override
  State<NoteHomeScreen> createState() => _NoteHomeScreenState();
}

class _NoteHomeScreenState extends State<NoteHomeScreen> {
  final AudioHelper _audioHelper = AudioHelper();
  final stt.SpeechToText _speech = stt.SpeechToText();
  
  List<NoteItem> _notes = [];
  bool _isListening = false;
  String _liveText = "";
  final TextEditingController _textController = TextEditingController();
  bool _showTextInput = false;
  
  String? _currentRecordingId;
  String? _currentRecordingPath;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _loadNotes();
  }

  Future<void> _requestPermissions() async {
    await [Permission.microphone, Permission.storage, Permission.speech].request();
  }

  Future<void> _loadNotes() async {
    // Artificial delay removed for speed, just load
    final notes = await DatabaseService().getNotes();
    setState(() => _notes = notes);
  }

  Future<void> _startRecording() async {
    bool available = await _speech.initialize();
    if (available) {
      setState(() => _isListening = true);
      _speech.listen(onResult: (result) {
        setState(() => _liveText = result.recognizedWords);
      });

      final dir = await getApplicationDocumentsDirectory();
      final id = const Uuid().v4();
      final path = '${dir.path}/$id.m4a';
      await _audioHelper.startRecording(path);
      
      _currentRecordingId = id;
      _currentRecordingPath = path;
    }
  }

  Future<void> _stopRecording() async {
    if (!_isListening) return;
    setState(() => _isListening = false);
    _speech.stop();
    await _audioHelper.stopRecording();

    if (_currentRecordingId != null && _liveText.isNotEmpty) {
      final note = NoteItem(
        id: _currentRecordingId!,
        type: NoteType.audio,
        content: _liveText,
        audioPath: _currentRecordingPath,
        createdAt: DateTime.now(),
      );
      await DatabaseService().insertNote(note);
      await _loadNotes();
      _liveText = "";
    }
  }

  void _addTextNote() async {
    if (_textController.text.trim().isEmpty) return;
    final note = NoteItem(
      id: const Uuid().v4(),
      type: NoteType.text,
      content: _textController.text,
      createdAt: DateTime.now(),
    );
    await DatabaseService().insertNote(note);
    await _loadNotes();
    _textController.clear();
    setState(() => _showTextInput = false);
  }

  void _deleteNote(String id) async {
    await DatabaseService().deleteNote(id);
    _loadNotes();
  }

  @override
  void dispose() {
    _audioHelper.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("IDS Note", style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(_showTextInput ? Icons.close : Icons.edit_note, color: Colors.cyanAccent),
            onPressed: () => setState(() => _showTextInput = !_showTextInput),
          )
        ],
      ),
      body: Column(
        children: [
          // Text Input
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: _showTextInput ? 80 : 0,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _showTextInput ? Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.grey[900],
                      hintText: "Write something...",
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  onPressed: _addTextNote,
                  icon: const Icon(Icons.send, color: Colors.cyanAccent),
                  style: IconButton.styleFrom(backgroundColor: Colors.grey[900]),
                )
              ],
            ) : null,
          ),

          // Listening Indicator
          if (_isListening)
             Container(
               width: double.infinity,
               color: Colors.red.withOpacity(0.1),
               padding: const EdgeInsets.all(10),
               child: Text("Listening: $_liveText", textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
             ),

          // Note List
          Expanded(
            child: _notes.isEmpty
                ? Center(child: Text("Tap mic to speak or + to write", style: TextStyle(color: Colors.grey[700])))
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _notes.length,
                    itemBuilder: (context, index) {
                      final note = _notes[index];
                      return Dismissible(
                        key: Key(note.id),
                        background: Container(color: Colors.red, child: const Icon(Icons.delete, color: Colors.white)),
                        onDismissed: (_) => _deleteNote(note.id),
                        child: Card(
                          color: Colors.grey[900],
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(
                              color: note.type == NoteType.audio ? Colors.cyanAccent.withOpacity(0.3) : Colors.deepPurpleAccent.withOpacity(0.3)
                            )
                          ),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: note.type == NoteType.audio ? Colors.cyanAccent.withOpacity(0.2) : Colors.deepPurpleAccent.withOpacity(0.2),
                              child: Icon(
                                note.type == NoteType.audio ? Icons.mic : Icons.text_fields,
                                color: note.type == NoteType.audio ? Colors.cyanAccent : Colors.deepPurpleAccent,
                              ),
                            ),
                            title: Text(note.content, maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              "${note.createdAt.toString().split('.')[0]}",
                              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                            ),
                            trailing: note.type == NoteType.audio
                                ? IconButton(
                                    icon: const Icon(Icons.play_circle_fill, color: Colors.white),
                                    onPressed: () => _audioHelper.playAudio(note.audioPath!),
                                  )
                                : null,
                            onTap: () {
                              showDialog(
                                context: context, 
                                builder: (_) => AlertDialog(
                                  backgroundColor: Colors.grey[900],
                                  title: Text(note.type == NoteType.audio ? "Voice Note" : "Text Note"),
                                  content: Text(note.content),
                                  actions: [
                                    if(note.type == NoteType.audio)
                                      TextButton(onPressed: () => _audioHelper.playAudio(note.audioPath!), child: const Text("Play")),
                                    TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close")),
                                  ],
                                )
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: GestureDetector(
        onLongPressStart: (_) => _startRecording(),
        onLongPressEnd: (_) => _stopRecording(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: _isListening ? 80 : 70,
          height: _isListening ? 80 : 70,
          decoration: BoxDecoration(
            color: _isListening ? Colors.red : Colors.cyanAccent,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _isListening ? Colors.red.withOpacity(0.6) : Colors.cyanAccent.withOpacity(0.6),
                blurRadius: 20,
                spreadRadius: 5
              )
            ]
          ),
          child: Icon(_isListening ? Icons.mic : Icons.mic_none, color: Colors.black, size: 30),
        ),
      ),
    );
  }
}
