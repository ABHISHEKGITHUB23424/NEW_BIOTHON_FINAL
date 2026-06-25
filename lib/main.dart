import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/auth_screen.dart';
import 'screens/donor_app.dart';
import 'screens/admin_app.dart';
import 'screens/coordinator_app.dart';
import 'data/local_db.dart';
import 'services/forecasting_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..loadSession(),
      child: const BloodSenseApp(),
    ),
  );
}

class BloodSenseApp extends StatelessWidget {
  const BloodSenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BloodSense',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFFF4F6F8),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF8B0000), // Deep Crimson Red
          secondary: Color(0xFFFAF8F5), // Cream
          surface: Colors.white,
          background: Color(0xFFF4F6F8),
          error: Color(0xFFD32F2F),
          onPrimary: Colors.white,
          onSurface: Color(0xFF2C2C2C),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: const Color(0xFFE2E8F0), width: 1),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF8B0000), // Crimson Header
          elevation: 1,
          centerTitle: true,
          iconTheme: IconThemeData(color: Colors.white),
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      builder: (context, child) {
        return Container(
          color: const Color(0xFF0F0E13), // Deep dark/neutral background for the outer area
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Container(
                decoration: const BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 20,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: child ?? const SizedBox(),
              ),
            ),
          ),
        );
      },
      home: const MainRouter(),
    );
  }
}

class MainRouter extends StatelessWidget {
  const MainRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    
    if (state.isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF3B30)),
          ),
        ),
      );
    }
    
    if (!state.isLoggedIn) {
      return const AuthScreen();
    }
    
    // Role-based routing
    switch (state.role) {
      case 'donor':
        return const DonorHomeScreen();
      case 'bank_admin':
        return const AdminDashboardScreen();
      case 'coordinator':
        return const CoordinatorHeatmapScreen();
      default:
        return const AuthScreen();
    }
  }
}

// Global Application State Manager
class AppState extends ChangeNotifier {
  bool _isLoading = true;
  bool _isLoggedIn = false;
  String _role = ''; // 'donor', 'bank_admin', 'coordinator'
  String _firebaseUid = '';
  String _name = '';
  String _bloodGroup = '';
  String _phone = '';
  String _city = 'Delhi NCR';
  int? _donorId;
  int? _bankId;
  String _token = '';
  String _backendUrl = 'http://localhost:8000'; // Default API Host
  
  // Simulation notifications
  Map<String, dynamic>? _pendingNotification;

  bool get isLoading => _isLoading;
  bool get isLoggedIn => _isLoggedIn;
  String get role => _role;
  String get firebaseUid => _firebaseUid;
  String get name => _name;
  String get bloodGroup => _bloodGroup;
  String get phone => _phone;
  String get city => _city;
  int? get donorId => _donorId;
  int? get bankId => _bankId;
  String get token => _token;
  String get backendUrl => _backendUrl;
  Map<String, dynamic>? get pendingNotification => _pendingNotification;

  Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _backendUrl = prefs.getString('backendUrl') ?? 'http://localhost:8000';
    _isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    _role = prefs.getString('role') ?? '';
    _firebaseUid = prefs.getString('firebaseUid') ?? '';
    _name = prefs.getString('name') ?? '';
    _bloodGroup = prefs.getString('bloodGroup') ?? '';
    _phone = prefs.getString('phone') ?? '';
    _city = prefs.getString('city') ?? 'Delhi NCR';
    _donorId = prefs.getInt('donorId');
    _bankId = prefs.getInt('bankId');
    _token = prefs.getString('token') ?? '';
    
    try {
      await LocalDatabase.instance.init();
      await ForecastingService.instance.trainAndCacheForecasts();
    } catch (e) {
      debugPrint('Error initializing local database/forecasting on loadSession: $e');
    }
    
    _isLoading = false;
    notifyListeners();
  }

  Future<void> setBackendUrl(String url) async {
    _backendUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backendUrl', url);
    notifyListeners();
  }

  Future<void> login(String role, String uid, Map<String, dynamic> profile, {String token = ''}) async {
    _role = role;
    _firebaseUid = uid;
    _isLoggedIn = true;
    _name = profile['name'] ?? '';
    _bloodGroup = profile['blood_group'] ?? 'O+';
    _phone = profile['phone'] ?? '';
    _city = profile['city'] ?? 'Delhi NCR';
    _donorId = profile['donor_id'];
    _bankId = profile['bank_id'];
    _token = token;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', true);
    await prefs.setString('role', role);
    await prefs.setString('firebaseUid', uid);
    await prefs.setString('name', _name);
    await prefs.setString('bloodGroup', _bloodGroup);
    await prefs.setString('phone', _phone);
    await prefs.setString('city', _city);
    await prefs.setString('token', _token);
    if (_donorId != null) await prefs.setInt('donorId', _donorId!);
    if (_bankId != null) await prefs.setInt('bankId', _bankId!);
    
    notifyListeners();
  }

  Future<void> logout() async {
    _isLoggedIn = false;
    _role = '';
    _firebaseUid = '';
    _name = '';
    _bloodGroup = '';
    _phone = '';
    _city = 'Delhi NCR';
    _donorId = null;
    _bankId = null;
    _token = '';
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('isLoggedIn');
    await prefs.remove('role');
    await prefs.remove('firebaseUid');
    await prefs.remove('name');
    await prefs.remove('bloodGroup');
    await prefs.remove('phone');
    await prefs.remove('city');
    await prefs.remove('donorId');
    await prefs.remove('bankId');
    await prefs.remove('token');
    
    notifyListeners();
  }

  // Simulates an FCM push notification trigger
  void triggerMockNotification(Map<String, dynamic> data) {
    _pendingNotification = data;
    notifyListeners();
  }

  void clearNotification() {
    _pendingNotification = null;
    notifyListeners();
  }
}
