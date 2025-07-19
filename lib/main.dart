import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;

const String geminiApiKey = 'AIzaSyAk73LwFLKQt-PTuqoX3L_RuF0gx8sQD7k';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chat boot',
      theme: ThemeData(primarySwatch: Colors.lightBlue),
      debugShowCheckedModeBanner: false,
      home: const LoginPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  bool _isLoading = false;

  // Speech‑to‑text
  late final stt.SpeechToText _speech;
  bool _isListening = false;
  String _lastWords = '';

  // Text‑to‑speech
  late final FlutterTts _flutterTts;
  bool _isSpeaking = false;
  int _currentSpeakingIndex = -1; // message index being read

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _initTts();
  }

  // edit message
  void _editMessage(int index) {
    final message = _messages[index]['content'] ?? '';
    final TextEditingController editController = TextEditingController(
      text: message,
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier le message'),
        content: TextField(
          controller: editController,
          maxLines: null,
          decoration: const InputDecoration(hintText: 'Nouveau message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newText = editController.text.trim();
              if (newText.isEmpty) return;

              setState(() {
                _messages[index]['content'] = newText;
              });

              // Supprimer l'ancienne réponse qui suit ce message utilisateur
              if (_messages.length > index + 1 &&
                  _messages[index + 1]['role'] == 'assistant') {
                setState(() {
                  _messages.removeAt(index + 1);
                });
              }

              Navigator.pop(context); // fermer la boîte de dialogue

              // Lancer une nouvelle requête avec le message modifié
              setState(() => _isLoading = true);
              final newReply = await _getGeminiResponse(newText);
              setState(() {
                _isLoading = false;
                _messages.insert(index + 1, {
                  'role': 'assistant',
                  'content': newReply ?? 'Désolé, pas de réponse.',
                });
              });
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  Future<void> _initTts() async {
    _flutterTts = FlutterTts();

    await _flutterTts.setLanguage('fr-FR');
    await _flutterTts.setLanguage('en-EN');
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);

    _flutterTts.setStartHandler(() {
      setState(() => _isSpeaking = true);
    });

    _flutterTts.setCompletionHandler(() {
      setState(() {
        _isSpeaking = false;
        _currentSpeakingIndex = -1;
      });
    });

    _flutterTts.setErrorHandler((msg) {
      setState(() {
        _isSpeaking = false;
        _currentSpeakingIndex = -1;
      });
      developer.log('TTS error: $msg', name: 'TTS');
    });
  }

  Future<void> _speak(String text, int messageIndex) async {
    if (text.isNotEmpty) {
      await _flutterTts.speak(text);
      setState(() => _currentSpeakingIndex = messageIndex);
    }
  }

  Future<void> _stopSpeaking() async {
    await _flutterTts.stop();
    if (!mounted) return;
    setState(() {
      _isSpeaking = false;
      _currentSpeakingIndex = -1;
    });
  }

  Future<void> _toggleSpeech(String text, int messageIndex) async {
    if (_isSpeaking && _currentSpeakingIndex == messageIndex) {
      await _stopSpeaking();
    } else {
      if (_isSpeaking) await _stopSpeaking();
      await _speak(text, messageIndex);
    }
  }

  Future<void> _startListening() async {
    final available = await _speech.initialize(
      onStatus: (status) {
        developer.log('Speech status: $status', name: 'STT');
        if (status == 'notListening' && _isListening) {
          setState(() => _isListening = false);
        }
      },
      onError: (error) {
        developer.log('Speech error: $error', name: 'STT');
        setState(() => _isListening = false);
      },
    );

    if (available) {
      setState(() => _isListening = true);
      _speech.listen(
        onResult: (result) {
          setState(() {
            _lastWords = result.recognizedWords;
            _controller.text = _lastWords;
          });
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reconnaissance vocale non disponible')),
      );
    }
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    if (mounted) setState(() => _isListening = false);
  }

  Future<void> _sendMessage() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;

    setState(() {
      _messages.add({'role': 'user', 'content': input});
      _isLoading = true;
    });

    _controller.clear();

    String? reply;
    try {
      reply = await _getGeminiResponse(input);
    } finally {
      if (!mounted) return;
      if (reply != null && reply.isNotEmpty) {
        setState(() {
          _messages.add({'role': 'assistant', 'content': reply!});
        });
      } else {
        setState(() {
          _messages.add({
            'role': 'assistant',
            'content': 'Désolé, pas de réponse.',
          });
        });
      }
      _isLoading = false;
    }
  }

  Future<String?> _getGeminiResponse(String prompt) async {
    try {
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$geminiApiKey',
      );

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt},
              ],
            },
          ],
          'generationConfig': {
            'temperature': 0.7,
            'topK': 40,
            'topP': 0.95,
            'maxOutputTokens': 1024,
          },
        }),
      );

      developer.log('Gemini status: ${response.statusCode}', name: 'API');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final parts = data['candidates']?[0]?['content']?['parts'];
        if (parts != null && parts.isNotEmpty) {
          return parts[0]['text'] as String;
        }
        return 'Réponse mal formatée de l\'API.';
      }

      // Handle errors
      final errorData = jsonDecode(response.body);
      final message = errorData['error']?['message'] ?? 'Erreur inconnue';
      return 'Erreur API (${response.statusCode}): $message';
    } catch (e, stack) {
      developer.log('API exception', name: 'API', error: e, stackTrace: stack);
      return 'Erreur de connexion. Vérifiez votre connexion internet.';
    }
  }

  @override
  void dispose() {
    _speech.stop();
    _flutterTts.stop();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Talk with Gemini'),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
        elevation: 4,
        shadowColor: const Color.fromARGB(198, 14, 14, 14),
        actions: [
          if (_isSpeaking)
            IconButton(
              tooltip: 'Arrêter la lecture',
              icon: const Icon(Icons.volume_off),
              onPressed: _stopSpeaking,
            ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Text(
                'Talk with Gemini',
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Historique'),
              onTap: () {
                // Tu peux créer une page d’historique ou afficher un modal
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Historique à venir...')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Déconnexion'),
              onTap: () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                );
              },
            ),
          ],
        ),
      ),

      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(10),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final reversedIndex = _messages.length - 1 - index;
                final msg = _messages[reversedIndex];
                final isUser = msg['role'] == 'user';

                return Align(
                  alignment: isUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    decoration: BoxDecoration(
                      color: isUser ? Colors.blue[900] : Colors.white,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(isUser ? 16 : 0),
                        bottomRight: Radius.circular(isUser ? 0 : 16),
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color.fromRGBO(0, 0, 0, 0.05),
                          blurRadius: 5,
                          offset: Offset(2, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: isUser
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        Text(
                          msg['content'] ?? '',
                          style: TextStyle(
                            fontSize: 16,
                            color: isUser ? Colors.white : Colors.black87,
                          ),
                        ),
                        if (!isUser)
                          Align(
                            alignment: Alignment.bottomRight,
                            child: IconButton(
                              icon: Icon(
                                (_isSpeaking &&
                                        _currentSpeakingIndex == reversedIndex)
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_fill,
                                color: Colors.blue[900],
                                size: 28,
                              ),
                              tooltip:
                                  (_isSpeaking &&
                                      _currentSpeakingIndex == reversedIndex)
                                  ? 'Arrêter la lecture'
                                  : 'Lire à voix haute',
                              onPressed: () => _toggleSpeech(
                                msg['content'] ?? '',
                                reversedIndex,
                              ),
                            ),
                          ),
                        if (isUser)
                          Align(
                            alignment: Alignment.bottomRight,
                            child: IconButton(
                              icon: const Icon(
                                Icons.edit,
                                color: Colors.white,
                                size: 20,
                              ),
                              tooltip: 'Modifier le message',
                              onPressed: () => _editMessage(reversedIndex),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (_isLoading) const LinearProgressIndicator(minHeight: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  blurRadius: 3,
                  color: Colors.grey.shade300,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _isListening ? _stopListening : _startListening,
                  child: CircleAvatar(
                    backgroundColor: _isListening
                        ? Colors.redAccent
                        : const Color.fromARGB(255, 73, 71, 200),
                    radius: 24,
                    child: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'Écrivez ou parlez...',
                      filled: true,
                      fillColor: Colors.grey[100],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(25),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  icon: const Icon(Icons.send),
                  color: Colors.blue[900],
                  onPressed: _isLoading ? null : _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  String _error = '';
  bool _obscureText = true;

  void _login() {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email == 'user@example.com' && password == '123456') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ChatPage()),
      );
    } else {
      setState(() => _error = 'Identifiants incorrects');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF0D47A1),
              Color(0xFF42A5F5),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Connexion',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 40),
                    
                    // Email Input
                    TextField(
                      controller: _emailController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Email',
                        labelStyle: const TextStyle(color: Colors.white70),
                        prefixIcon: const Icon(Icons.email, color: Colors.white),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Colors.white70),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Colors.white,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Password Input
                    TextField(
                      controller: _passwordController,
                      obscureText: _obscureText,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Mot de passe',
                        labelStyle: const TextStyle(color: Colors.white70),
                        prefixIcon: const Icon(Icons.lock, color: Colors.white),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureText ? Icons.visibility : Icons.visibility_off,
                            color: Colors.white70,
                          ),
                          onPressed: () {
                            setState(() {
                              _obscureText = !_obscureText;
                            });
                          },
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Colors.white70),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Colors.white,
                            width: 2,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 30),

                    // Login Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _login,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.blue[900],
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text(
                          'Se connecter',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),

                    if (_error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          _error,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Texte en bas de l'écran
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: const Center(
                child: Text(
                  'Created by ML',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}