import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:rive/rive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
class ThemeNotifier extends ChangeNotifier {
  static const String _themePrefKey = 'app_theme_mode';
  bool _isDarkMode = false;

  bool get isDarkMode => _isDarkMode;

  ThemeNotifier() {
    _loadThemePreference();
  }

  Future<void> _loadThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_themePrefKey) ?? false;
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    _isDarkMode = !_isDarkMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themePrefKey, _isDarkMode);
    notifyListeners();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: '',
    anonKey: '',
  );
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeNotifier(),
      child: const QuizApp(),
    ),
  );
}

// Modelisation
class QuizQuestion {
  final String question;
  final List<String> options;
  final int correctAnswerIndex;

  QuizQuestion({
    required this.question,
    required this.options,
    required this.correctAnswerIndex,
  });

  factory QuizQuestion.fromJson(Map<String, dynamic> json) {
    return QuizQuestion(
      question: json['question'] ?? 'Unknown Question',
      options: List<String>.from(json['options'] ?? []),
      correctAnswerIndex: json['answer_index'] ?? 0,
    );
  }
  Map<String, dynamic> toMap(String userId, String theme) {
    return {
      'user_id': userId,
      'theme': theme.trim(),
      'question': question,
      'options': options,
      'correct_index': correctAnswerIndex,
    };
  }
}

class UserProfile {
  final String id;
  final String username;
  final Map<String, ThemeKnowledge> themeKnowledge;

  UserProfile({
    required this.id,
    required this.username,
    required this.themeKnowledge,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    Map<String, ThemeKnowledge> themes = {};
    if (json['theme_knowledge'] != null) {
      final Map<String, dynamic> themeData = Map<String, dynamic>.from(json['theme_knowledge']);
      themeData.forEach((key, value) {
        themes[key] = ThemeKnowledge.fromJson(Map<String, dynamic>.from(value));
      });
    }

    return UserProfile(
      id: json['id'] ?? '',
      username: json['username'] ?? 'User',
      themeKnowledge: themes,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'theme_knowledge': themeKnowledge.map((key, value) => MapEntry(key, value.toJson())),
    };
  }
}

class ThemeKnowledge {
  final int totalQuestions;
  final int correctAnswers;
  final int quizzesTaken;

  ThemeKnowledge({
    required this.totalQuestions,
    required this.correctAnswers,
    required this.quizzesTaken,
  });

  double get accuracy => totalQuestions > 0 ? (correctAnswers / totalQuestions) * 100 : 0;

  factory ThemeKnowledge.fromJson(Map<String, dynamic> json) {
    return ThemeKnowledge(
      totalQuestions: json['total_questions'] ?? 0,
      correctAnswers: json['correct_answers'] ?? 0,
      quizzesTaken: json['quizzes_taken'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'total_questions': totalQuestions,
      'correct_answers': correctAnswers,
      'quizzes_taken': quizzesTaken,
    };
  }

  ThemeKnowledge copyWith({int? totalQuestions, int? correctAnswers, int? quizzesTaken}) {
    return ThemeKnowledge(
      totalQuestions: totalQuestions ?? this.totalQuestions,
      correctAnswers: correctAnswers ?? this.correctAnswers,
      quizzesTaken: quizzesTaken ?? this.quizzesTaken,
    );
  }
}


// supabase service
class SupabaseService {
  final SupabaseClient _client = Supabase.instance.client;
  static const String _localProfileKey = 'local_user_profile';
  static const String NO_INTERNET_ERROR = "NO_INTERNET";

  //authentification

  Future<String?> signUp({
    required String email,
    required String password,
    required String username
  }) async {
    try {
      final AuthResponse res = await _client.auth.signUp(
        email: email,
        password: password,
      );

      if (res.user == null) return "Sign up failed.";

      final newProfile = UserProfile(
        id: res.user!.id,
        username: username,
        themeKnowledge: {},
      );

      //Cloud Save
      await _client.from('user_profiles').insert({
        'id': newProfile.id,
        'username': newProfile.username,
        'email': email,
        'theme_knowledge': {},
      });

      // 2. Local Save
      await _saveProfileLocally(newProfile);

      return null;
    } on SocketException {
      return NO_INTERNET_ERROR;
    } on AuthException catch (e) {

      if (e.message.contains("Socket") || e.message.contains("network")) return NO_INTERNET_ERROR;
      return e.message;
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        await _client.auth.signOut();
        return "Username already taken.";
      }
      return "Database error: ${e.message}";
    } catch (e) {
      if (e.toString().contains("SocketException")) return NO_INTERNET_ERROR;
      return "Error: $e";
    }
  }

  Future<String?> signIn({required String email, required String password}) async {
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
      return null;
    } on SocketException {
      return NO_INTERNET_ERROR;
    } on AuthException catch (e) {
      if (e.message.contains("Socket") || e.message.contains("network")) return NO_INTERNET_ERROR;
      return e.message;
    } catch (e) {
      if (e.toString().contains("SocketException")) return NO_INTERNET_ERROR;
      return "Login failed.";
    }
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_localProfileKey);
  }

  // DATA MANAGEMENT

  Future<UserProfile?> getUserProfile(String userId) async {
    // 1. Cache First
    final localData = await _getLocalProfile();

    if (localData != null && localData.id == userId) {
      _fetchAndSaveNetworkProfile(userId);
      return localData;
    }

    // Network Fallback
    return await _fetchAndSaveNetworkProfile(userId);
  }

  Future<UserProfile?> _fetchAndSaveNetworkProfile(String userId) async {
    try {
      final response = await _client.from('user_profiles').select().eq('id', userId).single();
      final profile = UserProfile.fromJson(response);
      await _saveProfileLocally(profile);
      return profile;
    } catch (e) {
      return null;
    }
  }

  Future<void> _saveProfileLocally(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    String jsonString = jsonEncode(profile.toJson());
    await prefs.setString(_localProfileKey, jsonString);
  }

  Future<UserProfile?> _getLocalProfile() async {
    final prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString(_localProfileKey);
    if (jsonString == null) return null;
    try {
      return UserProfile.fromJson(jsonDecode(jsonString));
    } catch (e) {
      return null;
    }
  }

  Future<void> updateThemeKnowledge(String userId, String theme, int questions, int correct) async {
    final normalizedTheme = theme.trim();

    // 1. Update Local
    final localProfile = await _getLocalProfile();
    if (localProfile != null && localProfile.id == userId) {
      final current = localProfile.themeKnowledge[normalizedTheme] ??
          ThemeKnowledge(totalQuestions: 0, correctAnswers: 0, quizzesTaken: 0);

      final updatedStats = current.copyWith(
        totalQuestions: current.totalQuestions + questions,
        correctAnswers: current.correctAnswers + correct,
        quizzesTaken: current.quizzesTaken + 1,
      );

      final newThemes = Map<String, ThemeKnowledge>.from(localProfile.themeKnowledge);
      newThemes[normalizedTheme] = updatedStats;

      final newProfile = UserProfile(id: userId, username: localProfile.username, themeKnowledge: newThemes);
      await _saveProfileLocally(newProfile);
    }

    //Update Cloud
    try {
      final existingProfile = await _client.from('user_profiles').select().eq('id', userId).single();
      final serverProfile = UserProfile.fromJson(existingProfile);

      final current = serverProfile.themeKnowledge[normalizedTheme] ??
          ThemeKnowledge(totalQuestions: 0, correctAnswers: 0, quizzesTaken: 0);

      final updated = current.copyWith(
        totalQuestions: current.totalQuestions + questions,
        correctAnswers: current.correctAnswers + correct,
        quizzesTaken: current.quizzesTaken + 1,
      );

      final updatedThemes = Map<String, ThemeKnowledge>.from(serverProfile.themeKnowledge);
      updatedThemes[normalizedTheme] = updated;

      await _client.from('user_profiles').update({
        'theme_knowledge': updatedThemes.map((key, value) => MapEntry(key, value.toJson())),
      }).eq('id', userId);
    } catch (e) {
      print("Sync error (ignored): $e");
    }
  }

  Future<List<String>> getUserThemes(String userId) async {
    final profile = await getUserProfile(userId);
    return profile?.themeKnowledge.keys.toList() ?? [];
  }
  Future<void> saveQuizResults(String userId, String theme, List<QuizQuestion> questions, int score) async {
    await updateThemeKnowledge(userId, theme, questions.length, score);

    // Insertion des questions dans quiz_history
    try {
      final historyData = questions.map((q) => q.toMap(userId, theme)).toList();

      // upsert avec ignoreDuplicates: true utilise la contrainte UNIQUE
      // pour ne pas créer d'erreur si la question existe déjà
      await _client.from('quiz_history').upsert(
          historyData,
          onConflict: 'user_id, question',
          ignoreDuplicates: true
      );
    } catch (e) {
      print("Erreur lors de la sauvegarde de l'historique: $e");
    }
  }

  //récupérer historique
  Future<List<QuizQuestion>> getHistoryForTheme(String userId, String theme) async {
    try {
      final response = await _client
          .from('quiz_history')
          .select()
          .eq('user_id', userId)
          .eq('theme', theme.trim());

      final List<dynamic> data = response;
      return data.map((json) => QuizQuestion(
        question: json['question'],
        options: List<String>.from(json['options']),
        correctAnswerIndex: json['correct_index'],
      )).toList();
    } catch (e) {
      print("Erreur fetch history: $e");
      return [];
    }
  }
}
//Historique
class HistoryScreen extends StatelessWidget {
  final String userId;
  final String themeName;

  const HistoryScreen({super.key, required this.userId, required this.themeName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(themeName.toUpperCase()),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: FutureBuilder<List<QuizQuestion>>(
        future: SupabaseService().getHistoryForTheme(userId, themeName),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final questions = snapshot.data ?? [];

          if (questions.isEmpty) {
            return const Center(child: Text("No questions saved yet for this topic."));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: questions.length,
            itemBuilder: (context, index) {
              final q = questions[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 16),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Question ${index + 1}",
                        style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(q.question, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                      const Divider(height: 32),
                      const Text("Correct Answer:", style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 4),
                      Text(
                        q.options[q.correctAnswerIndex],
                        style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
//GEMINI
class QuizService {
  final String apiKey = '';

  final List<String> _styles = [
    "Focus on lesser-known facts.",
    "Focus on historical context.",
    "Focus on technical details.",
    "Focus on common misconceptions.",
    "Mix between easy,medium and hard questions",
    "Provide short answers",
  ];
  Future<List<QuizQuestion>> generateQuiz({
    required String topic,
    required int numQuestions,
    required int numOptions,
  }) async {
    final model = GenerativeModel(
      model: 'gemini-2.5-flash-lite',
      apiKey: apiKey,
      generationConfig: GenerationConfig(
        temperature: 0.7,
        responseMimeType: 'application/json',
      ),
    );
    final randomStyle = _styles[Random().nextInt(_styles.length)];
    final prompt = '''
      Generate a quiz about "$topic".
      Constraint: $randomStyle
      Requirements:
      1. Exactly $numQuestions questions.
      2. Exactly $numOptions options per question.
      3. Questions must be unique.
      Schema: [{"question": "txt", "options": ["A", "B"], "answer_index": 0}]
    ''';
    try {
      final response = await model.generateContent([Content.text(prompt)]);
      if (response.text == null) return [];
      String cleanText = response.text!.replaceAll('```json', '').replaceAll('```', '').trim();
      final List<dynamic> data = jsonDecode(cleanText);
      return data.map((e) => QuizQuestion.fromJson(e)).toList();
    } catch (e) {
      throw Exception("Failed to generate quiz.");
    }
  }
}
//main app
class QuizApp extends StatelessWidget {
  const QuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeNotifier>(
      builder: (context, themeNotifier, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Quizzy',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6C63FF),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
            fontFamily: 'Roboto',
            scaffoldBackgroundColor: const Color(0xFFF5F7FA),
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6C63FF),
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
            fontFamily: 'Roboto',
            scaffoldBackgroundColor: const Color(0xFF121212),
          ),
          themeMode: themeNotifier.isDarkMode ? ThemeMode.dark : ThemeMode.light,
          home: const AuthGate(),
        );
      },
    );
  }
}
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}
class _AuthGateState extends State<AuthGate> {
  final _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    await Future.delayed(Duration.zero);
    final session = _supabase.auth.currentSession;
    if (session != null) {
      Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => HomeScreen(userId: session.user.id))
      );
    } else {
      Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const WelcomeScreen())
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

//Welcome
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Center(
                child: SizedBox(
                  width: 250,
                  height: 250,
                  child: RiveAnimation.asset(
                    'assets/geometric_shape_loader.riv',
                    fit: BoxFit.contain,
                    stateMachines: const ['State Machine 1'],
                  ),
                ),
              ),
              const SizedBox(height: 40),
              Text(
                "Welcome to Quizzy!",
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: Theme.of(context).textTheme.bodyLarge?.color ?? Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                "Your home for quizzes\nand gaining knowledge",
                style: TextStyle(
                  fontSize: 18,
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (context) => const AuthScreen()));
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text("It's time for quizzes", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,color: Theme.of(context).colorScheme.onPrimary)),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward_rounded,color: Theme.of(context).colorScheme.onPrimary,),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}


//ecran d'authentification
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final SupabaseService _authService = SupabaseService();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _userCtrl = TextEditingController();

  bool _isLogin = true;
  bool _isLoading = false;

  void _submit() async {
    if (_emailCtrl.text.isEmpty || _passCtrl.text.isEmpty) return;
    if (!_isLogin && _userCtrl.text.isEmpty) return;

    setState(() => _isLoading = true);

    String? error;
    if (_isLogin) {
      error = await _authService.signIn(email: _emailCtrl.text.trim(), password: _passCtrl.text.trim());
    } else {
      error = await _authService.signUp(
          email: _emailCtrl.text.trim(),
          password: _passCtrl.text.trim(),
          username: _userCtrl.text.trim()
      );
    }

    setState(() => _isLoading = false);

    if (error != null) {
      if (error == SupabaseService.NO_INTERNET_ERROR) {
        _showNoInternetDialog();
      } else {
        if(mounted) ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error),
              backgroundColor: Colors.red,
            )
        );
      }
    } else {
      if (mounted) {
        final userId = Supabase.instance.client.auth.currentUser!.id;
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => HomeScreen(userId: userId)),
              (route) => false,
        );
      }
    }
  }

  void _showNoInternetDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.wifi_off_rounded, size: 40, color: Colors.orange.shade400),
            ),
            const SizedBox(height: 16),
            Text(
              "No Internet",
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).textTheme.bodyLarge?.color,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "You need an internet connection to ${_isLogin ? 'log in' : 'sign up'}.",
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).textTheme.bodyMedium?.color,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text("OK", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            )
          ],
        ),
      ),
    );
  }

  InputDecoration _buildInputDecoration(String labelText, String hintText, IconData icon) {
    return InputDecoration(
      labelText: labelText,
      labelStyle: TextStyle(
        color: Theme.of(context).colorScheme.primary,
      ),
      hintText: hintText,
      hintStyle: TextStyle(
        color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.5),
      ),
      prefixIcon: Icon(
        icon,
        color: Theme.of(context).colorScheme.primary,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
      ),
      filled: true,
      fillColor: Theme.of(context).colorScheme.surfaceContainer,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(
          color: Theme.of(context).textTheme.bodyLarge?.color,
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(
                Icons.bolt_rounded,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                _isLogin ? "Welcome Back" : "Create Account",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).textTheme.bodyLarge?.color,
                ),
              ),
              const SizedBox(height: 40),
              TextField(
                controller: _emailCtrl,
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodyLarge?.color,
                ),
                decoration: _buildInputDecoration("Email", "your@email.com", Icons.email),
              ),
              const SizedBox(height: 16),
              if (!_isLogin) ...[
                TextField(
                  controller: _userCtrl,
                  style: TextStyle(
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                  decoration: _buildInputDecoration("Username", "Unique username", Icons.person),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _passCtrl,
                obscureText: true,
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodyLarge?.color,
                ),
                decoration: _buildInputDecoration("Password", "Enter password", Icons.lock),
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: _isLoading
                      ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                      : Text(
                    _isLogin ? "Login" : "Sign Up",
                    style: TextStyle(fontWeight: FontWeight.bold,color: Theme.of(context).colorScheme.onPrimary),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => setState(() => _isLogin = !_isLogin),
                child: Text(
                  _isLogin ? "Need an account? Sign Up" : "Have an account? Login",
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

//Home Screen
class HomeScreen extends StatefulWidget {
  final String userId;
  const HomeScreen({super.key, required this.userId});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _idx = 0;

  void _goToProfile() {
    setState(() => _idx = 1);
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      ConfigScreen(userId: widget.userId, onGoToProfile: _goToProfile),
      ProfileScreen(userId: widget.userId),
    ];

    return PopScope(
      canPop: _idx == 0,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        setState(() => _idx = 0);
      },
      child: Scaffold(
        body: screens[_idx],
        bottomNavigationBar: NavigationBar(
          selectedIndex: _idx,
          onDestinationSelected: (i) => setState(() => _idx = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.psychology_outlined), selectedIcon: Icon(Icons.psychology), label: 'Quiz'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}
class ConfigScreen extends StatefulWidget {
  final String userId;
  final VoidCallback onGoToProfile;

  const ConfigScreen({
    super.key,
    required this.userId,
    required this.onGoToProfile,
  });

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _topicCtrl = TextEditingController();
  final _quizService = QuizService();
  final _supabase = SupabaseService();

  double _numQuestions = 5;
  double _numOptions = 4;
  bool _isLoading = false;
  bool _hasConnectionError = false;

  String _username = '';
  List<String> _savedThemes = [];

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  void _fetchData() async {
    final p = await _supabase.getUserProfile(widget.userId);
    final t = await _supabase.getUserThemes(widget.userId);
    if(mounted) setState(() { _username = p?.username ?? 'User'; _savedThemes = t; });
  }

  void _generate() async {
    if (_topicCtrl.text.isEmpty) return;

    setState(() {
      _isLoading = true;
      _hasConnectionError = false;
    });
    FocusScope.of(context).unfocus();

    try {
      final quizTask = _quizService.generateQuiz(
        topic: _topicCtrl.text,
        numQuestions: _numQuestions.toInt(),
        numOptions: _numOptions.toInt(),
      );

      final waitTask = Future.delayed(const Duration(seconds: 3));

      final res = await Future.wait([quizTask, waitTask]);
      final questions = res[0] as List<QuizQuestion>;

      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => QuizScreen(questions: questions, topic: _topicCtrl.text, userId: widget.userId)),
        );
        _fetchData();
      }
    } catch (e) {
      print("Error generating quiz: $e");
      if (mounted) {
        setState(() {
          _hasConnectionError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    //pas d'internet
    if (_hasConnectionError) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [

                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(color: Colors.orange.shade50, shape: BoxShape.circle),
                  child: Icon(Icons.wifi_off_rounded, size: 60, color: Colors.orange.shade400),
                ),
                const SizedBox(height: 24),
                const Text("No Internet Connection", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(
                  "I cannot generate a new quiz right now, but you can still check your profile.",
                  style: TextStyle(fontSize: 16, color: Colors.grey.shade600, height: 1.5),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: widget.onGoToProfile,
                    icon: const Icon(Icons.person),
                    label: const Text("Check My Profile"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: () => setState(() => _hasConnectionError = false),
                  icon: const Icon(Icons.refresh),
                  label: const Text("Try Again"),
                )
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: Stack(
        children: [
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 40),
                  Text(
                    "Hello, $_username! ",
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).textTheme.bodyLarge?.color,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "What do you want to learn?",
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 30),

                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        )
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_savedThemes.isNotEmpty) ...[
                          Wrap(
                            spacing: 8,
                            children: _savedThemes.take(3).map((t) => ActionChip(
                              label: Text(
                                t,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onPrimary,
                                ),
                              ),
                              onPressed: () => setState(() => _topicCtrl.text = t),
                              backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.8),
                            )).toList(),
                          ),
                          const SizedBox(height: 20),
                        ],
                        TextField(
                          controller: _topicCtrl,
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodyLarge?.color,
                          ),
                          decoration: InputDecoration(
                            hintText: "Enter Topic...",
                            hintStyle: TextStyle(
                              color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.5),
                            ),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surfaceContainer,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide.none,
                            ),
                            prefixIcon: Icon(
                              Icons.search,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              "Questions",
                              style: TextStyle(
                                color: Theme.of(context).textTheme.bodyLarge?.color,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              "${_numQuestions.toInt()}",
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          ],
                        ),
                        Slider(
                          value: _numQuestions,
                          min: 3,
                          max: 15,
                          divisions: 12,
                          onChanged: (v) => setState(() => _numQuestions = v),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              "Options",
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              "${_numOptions.toInt()}",
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          ],
                        ),
                        Slider(
                          value: _numOptions,
                          min: 2,
                          max: 5,
                          divisions: 3,
                          onChanged: (v) => setState(() => _numOptions = v),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          height: 50,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _generate,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.primary,
                              foregroundColor: Colors.white,
                            ),
                            child: Text("Generate Quiz",style: TextStyle(color: Theme.of(context).colorScheme.onPrimary,)),
                          ),
                        )
                      ],
                    ),
                  )
                ],
              ),
            ),
          ),
          //quiz generation
          if (_isLoading)
            Container(
              color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.96),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 250,
                      height: 250,
                      child: RiveAnimation.asset(
                        'assets/tick.riv',
                        artboard: 'Magic',
                        fit: BoxFit.contain,
                        animations: ['Idle'],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      "Your quiz is getting crafted...",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).textTheme.bodyLarge?.color,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
// Profile
class ProfileScreen extends StatefulWidget {
  final String userId;
  const ProfileScreen({super.key, required this.userId});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _supabase = SupabaseService();
  UserProfile? _profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() async {
    final p = await _supabase.getUserProfile(widget.userId);
    if (mounted) setState(() => _profile = p);
  }

  void _logout() async {
    await _supabase.signOut();
    if(mounted) {
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => const WelcomeScreen()), (r) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_profile == null) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      appBar: AppBar(
        title: const Text("Profile"),
        actions: [IconButton(onPressed: _logout, icon: const Icon(Icons.logout, color: Colors.red))],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            CircleAvatar(radius: 40, backgroundColor: Theme.of(context).colorScheme.primary, child: Text(_profile!.username.isNotEmpty ? _profile!.username[0].toUpperCase() : '?', style: const TextStyle(fontSize: 30, color: Colors.white))),
            const SizedBox(height: 10),
            Text(_profile!.username, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 30),
            const Divider(),

            //dark mode
            Container(
              margin: const EdgeInsets.only(bottom: 30),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        context.watch<ThemeNotifier>().isDarkMode ? Icons.dark_mode : Icons.light_mode,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        "Dark Mode",
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                  Switch(
                    value: context.watch<ThemeNotifier>().isDarkMode,
                    onChanged: (_) {
                      context.read<ThemeNotifier>().toggleTheme();
                    },
                  ),
                ],
              ),
            ),

            if (_profile!.themeKnowledge.isEmpty)
              const Padding(padding: EdgeInsets.all(20), child: Text("No quizzes taken yet."))
            else
              ..._profile!.themeKnowledge.entries.map((e) => Card(
                child: ListTile(
                  title: Text(e.key.toUpperCase()),
                  subtitle: Text("${e.value.accuracy.toStringAsFixed(0)}% Accuracy"),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => HistoryScreen(
                          userId: widget.userId,
                          themeName: e.key,
                        ),
                      ),
                    );
                  },
                ),
              )),
          ],
        ),
      ),
    );
  }
}
// partie écran quiz
class QuizScreen extends StatefulWidget {
  final List<QuizQuestion> questions;
  final String topic;
  final String userId;
  const QuizScreen({super.key, required this.questions, required this.topic, required this.userId});

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  int _idx = 0;
  int _score = 0;
  bool _answered = false;
  int? _sel;

  void _ans(int i) {
    if (_answered) return;
    setState(() {
      _answered = true;
      _sel = i;
      if (i == widget.questions[_idx].correctAnswerIndex) _score++;
    });

    Future.delayed(const Duration(milliseconds: 1500), () {
      if (_idx < widget.questions.length - 1) {
        setState(() { _idx++; _answered = false; _sel = null; });
      } else {
        _end();
      }
    });
  }

  void _end() async {
    //Sauvegarde des données
    await SupabaseService().saveQuizResults(
        widget.userId,
        widget.topic,
        widget.questions,
        _score
    );
    //Affichage du résultat avec Animation
    if(mounted) {
      showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            contentPadding: const EdgeInsets.all(24),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  height: 150,
                  width: 150,
                  child: RiveAnimation.asset(
                    'assets/tick.riv',
                    fit: BoxFit.contain,
                    artboard: 'Tick',
                    stateMachines: const ['State appear'],
                  ),
                ),
                const SizedBox(height: 16),

                const Text(
                  "Quiz Finished!",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold,color: Colors.black),
                ),
                const SizedBox(height: 8),

                Text(
                  "You scored $_score / ${widget.questions.length}",
                  style: TextStyle(
                      fontSize: 18,
                      color: Colors.black,
                      fontWeight: FontWeight.w500
                  ),
                ),

                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: const Text("Awesome!", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                )
              ],
            ),
          )
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.questions[_idx];
    return Scaffold(
      appBar: AppBar(title: Text("Question ${_idx + 1}"), automaticallyImplyLeading: false),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            LinearProgressIndicator(
              value: (_idx + 1) / widget.questions.length,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 30),
            Text(q.question, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
            const Spacer(),
            ...List.generate(q.options.length, (i) {
              Color col = Colors.white;
              Color borderCol = Colors.grey.shade300;

              if (_answered) {
                if (i == q.correctAnswerIndex) {
                  col = Colors.green.shade50;
                  borderCol = Colors.green;
                } else if (i == _sel) {
                  col = Colors.red.shade50;
                  borderCol = Colors.red;
                }
              }

              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _ans(i),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: col,
                        border: Border.all(color: borderCol, width: 1.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                              color: borderCol == Colors.grey.shade300 ? Colors.grey.shade200 : borderCol,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                String.fromCharCode(65 + i),
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: borderCol == Colors.grey.shade300 ? Colors.grey.shade600 : Theme.of(context).colorScheme.onPrimary
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              q.options[i],
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500,color: Theme.of(context).colorScheme.onPrimary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}