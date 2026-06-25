import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../main.dart';
import '../utils/file_picker_helper.dart';
import '../data/india_locations.dart';
import '../widgets/location_picker_field.dart';
import '../services/auth_service.dart';
import '../data/local_db.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  // Navigation states
  // 0 = Landing Dashboard with Mission Statement and Portal Selectors
  // 1 = Donor Portal (Login / Register Toggle)
  // 2 = Admin Portal (Login)
  // 3 = Donor Registration Form
  int _currentView = 0;
  
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _otpController = TextEditingController();
  
  bool _isRegistering = false; // Toggle between Login and Register inside Donor portal
  bool _isVerifying = false;
  String? _errorMessage;
  
  // Registration Form Controllers
  final _regNameController = TextEditingController();
  final _regPhoneController = TextEditingController();
  final _regPasswordController = TextEditingController();
  final _regCityController = TextEditingController();
  String _regSelectedBloodGroup = 'O+';
  IndiaLocation? _regSelectedLocation;
  DateTime _regSelectedDob = DateTime.now().subtract(const Duration(days: 22 * 365));
  bool _regLocationPermission = true;
  PickedFile? _selectedIdDocument;
  bool _regConsentGiven = false;

  // Admin Registration Form Controllers
  final _adminRegNameController = TextEditingController();
  final _adminRegPhoneController = TextEditingController();
  final _adminRegPasswordController = TextEditingController();
  final _adminRegAddressController = TextEditingController();
  final _adminRegWebsiteController = TextEditingController();
  
  IndiaLocation? _adminRegSelectedLocation;
  DateTime _adminRegSelectedEstDate = DateTime.now().subtract(const Duration(days: 10 * 365));
  PickedFile? _adminRegSelectedDoc;
  PickedFile? _adminRegSelectedDatabaseFile;
  bool _adminRegConsentGiven = false;

  // Landing Page Interactive State
  int _activeServiceTab = 0;
  IndiaLocation? _searchSelectedLocation;
  String _searchSelectedBloodGroup = 'O+';
  List<dynamic> _searchResults = [];
  bool _isSearching = false;

  // --- Animated Nationwide Presence Section ---
  late AnimationController _bgSlideController;
  late AnimationController _counterController;
  late AnimationController _pulseController;
  late Animation<double> _bgSlideAnimation;
  late Animation<double> _counterAnimation;
  late Animation<double> _pulseAnimation;
  bool _sectionVisible = false;
  final GlobalKey _presenceKey = GlobalKey();

  int _calculateAge(DateTime birthDate) {
    DateTime today = DateTime.now();
    int age = today.year - birthDate.year;
    if (today.month < birthDate.month || (today.month == birthDate.month && today.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  @override
  void initState() {
    super.initState();
    // Background parallax animation (continuous, loops)
    _bgSlideController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat(reverse: true);
    _bgSlideAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _bgSlideController, curve: Curves.easeInOut),
    );

    // Counter animation (0 → full value over 2.5s)
    _counterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    _counterAnimation = CurvedAnimation(
      parent: _counterController,
      curve: Curves.easeOutCubic,
    );

    // Pulse animation for live indicator
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Trigger counters after a short delay
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _counterController.forward();
    });
  }

  @override
  void dispose() {
    _bgSlideController.dispose();
    _counterController.dispose();
    _pulseController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    _regNameController.dispose();
    _regPhoneController.dispose();
    _regPasswordController.dispose();
    _regCityController.dispose();
    _adminRegNameController.dispose();
    _adminRegPhoneController.dispose();
    _adminRegPasswordController.dispose();
    _adminRegAddressController.dispose();
    _adminRegWebsiteController.dispose();
    super.dispose();
  }

  String _parseErrorDetail(dynamic detail, {String fallback = 'An error occurred'}) {
    if (detail == null) return fallback;
    if (detail is String) return detail;
    if (detail is List) {
      try {
        return detail.map((e) {
          if (e is Map && e.containsKey('msg')) {
            final loc = e['loc'] is List ? (e['loc'] as List).join('.') : '';
            final msg = e['msg'] ?? '';
            return loc.isNotEmpty ? '$loc: $msg' : '$msg';
          }
          return e.toString();
        }).join(', ');
      } catch (_) {
        return detail.toString();
      }
    }
    return detail.toString();
  }

  Future<void> _handleLogin(String phone, String password, String role) async {
    if (role == 'coordinator' && _searchSelectedLocation == null) {
      setState(() => _errorMessage = 'Please select your Operating Region.');
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorMessage = null;
    });

    String finalPhone = phone.trim();
    if (RegExp(r'^\d{10}$').hasMatch(finalPhone)) {
      finalPhone = '+91$finalPhone';
    }

    final state = Provider.of<AppState>(context, listen: false);
    
    try {
      final res = await AuthService.instance.login(finalPhone, password, role);
      final uid = res['profile']['firebase_uid'] ?? '';
      final resRole = res['role'];
      final profile = Map<String, dynamic>.from(res['profile']);
      if (resRole == 'coordinator') {
        profile['city'] = _searchSelectedLocation!.name;
      }
      final token = res['token'] ?? '';
      await state.login(resRole, uid, profile, token: token);
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isVerifying = false;
      });
    }
  }

  Future<void> _handleRegister() async {
    if (_regSelectedLocation == null) {
      setState(() => _errorMessage = "Please select your Area / Region.");
      return;
    }

    if (_regNameController.text.isEmpty || _regPhoneController.text.isEmpty || _regPasswordController.text.isEmpty) {
      setState(() => _errorMessage = "Please fill in all details.");
      return;
    }

    final String fullPhone = '+91${_regPhoneController.text.trim()}';
    final phoneRegex = RegExp(r"^\+91[6-9]\d{9}$");
    if (!phoneRegex.hasMatch(fullPhone)) {
      setState(() => _errorMessage = "Mobile number must be in format +91 followed by 10 digits starting with 6-9.");
      return;
    }

    final passwordRegex = RegExp(r"^(?=.*[0-9]).{8,}$");
    if (!passwordRegex.hasMatch(_regPasswordController.text)) {
      setState(() => _errorMessage = "Password must be at least 8 characters long and contain at least one digit.");
      return;
    }

    final age = _calculateAge(_regSelectedDob);
    if (age < 15) {
      setState(() => _errorMessage = "You must be 15 years or older to register.");
      return;
    }

    if (_selectedIdDocument == null) {
      setState(() => _errorMessage = "Identity verification document is required.");
      return;
    }

    if (!_regConsentGiven) {
      setState(() => _errorMessage = "You must give consent under DPDP Act 2023 to register.");
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorMessage = null;
    });

    final state = Provider.of<AppState>(context, listen: false);

    // Map selected city/region to standard coordinate centers from IndiaLocation list
    final location = _regSelectedLocation!;
    double lat = location.latitude;
    double lng = location.longitude;

    // Add randomized jitter to coordinates so donors are scattered realistically
    final seconds = DateTime.now().second;
    lat += (0.015 * ((seconds % 4) - 2));
    lng += (0.015 * ((seconds % 3) - 1));

    try {
      final created = await AuthService.instance.registerDonor(
        name: _regNameController.text.trim(),
        phone: fullPhone,
        password: _regPasswordController.text,
        dob: _regSelectedDob.toIso8601String().split('T')[0],
        lat: lat,
        lng: lng,
        consent: _regConsentGiven,
        idDocBase64: _selectedIdDocument?.base64Content,
        idDocName: _selectedIdDocument?.name,
      );

      final uid = created['firebase_uid'] ?? '';
      final profile = {
        'name': created['name'],
        'blood_group': _regSelectedBloodGroup,
        'phone': fullPhone,
        'city': _regSelectedLocation!.name,
        'donor_id': created['donor_id'],
      };

      await LocalDatabase.instance.update('donors', 'donor_id', created['donor_id'] as int, {
        'blood_group': _regSelectedBloodGroup,
      });

      profile['blood_group'] = _regSelectedBloodGroup;

      final token = 'mock_jwt_token_donor_${created['donor_id']}';
      await state.login('donor', uid, profile, token: token);
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isVerifying = false;
      });
    }
  }

  void _showBackendSettings() {
    final state = Provider.of<AppState>(context, listen: false);
    final controller = TextEditingController(text: state.backendUrl);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Server Configuration'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'FastAPI Backend URL',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              state.setBackendUrl(controller.text);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _currentView == 0
          ? null
          : AppBar(
              title: const Text('BLOODSENSE'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  setState(() {
                    _currentView = 0;
                    _errorMessage = null;
                  });
                },
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings, color: Colors.grey),
                  onPressed: _showBackendSettings,
                )
              ],
            ),
      body: SafeArea(
        child: _currentView == 0
            ? SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildAppHeader(),
                    _buildNavBar(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_errorMessage != null) ...[
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF3B30).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFFFF3B30).withOpacity(0.3)),
                              ),
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(color: Color(0xFFFF3B30), fontSize: 13),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          ..._buildLandingViewContent(),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            : Center(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_errorMessage != null) ...[
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF3B30).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFFFF3B30).withOpacity(0.3)),
                              ),
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(color: Color(0xFFFF3B30), fontSize: 13),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: const Color(0xFFE2E8F0)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.06),
                                  blurRadius: 20,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  height: 4,
                                  color: const Color(0xFF8B0000),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      if (_currentView == 1) ..._buildDonorPortal(),
                                      if (_currentView == 2) ..._buildAdminPortal(),
                                      if (_currentView == 3) ..._buildDonorRegistrationForm(),
                                      if (_currentView == 4) ..._buildAdminRegistrationForm(),
                                      if (_currentView == 5) ..._buildCoordinatorPortal(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  // --- VIEW 0: LANDING DASHBOARD CONTENT (BloodSense Style) ---
  Widget _buildAppHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                const Icon(Icons.favorite, size: 36, color: Color(0xFF8B0000)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'BloodSense',
                        style: TextStyle(fontSize: 22, color: Color(0xFF8B0000), fontWeight: FontWeight.w900, letterSpacing: 0.5),
                      ),
                      Text(
                        'Smart Blood Inventory & Mobilization Network',
                        style: TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.w600, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF8B0000).withOpacity(0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              children: [
                Icon(Icons.check_circle, size: 14, color: Color(0xFF8B0000)),
                SizedBox(width: 6),
                Text(
                  'Active & Verified',
                  style: TextStyle(fontSize: 11, color: Color(0xFF8B0000), fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavBar() {
    return Container(
      color: const Color(0xFF8B0000),
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildNavBarItem('Home', active: _currentView == 0, onTap: () {
              setState(() {
                _currentView = 0;
                _errorMessage = null;
              });
            }),
            _buildNavBarItem('Donor Portal', active: _currentView == 1, onTap: () {
              setState(() {
                _currentView = 1;
                _errorMessage = null;
              });
            }),
            _buildNavBarItem('Blood Centre Portal', active: _currentView == 2, onTap: () {
              setState(() {
                _currentView = 2;
                _errorMessage = null;
              });
            }),
            _buildNavBarItem('Coordinator Portal', active: _currentView == 5, onTap: () {
              setState(() {
                _currentView = 5;
                _errorMessage = null;
              });
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildNavBarItem(String label, {bool active = false, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap ?? () {},
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? Colors.black26 : Colors.transparent,
          border: const Border(
            right: BorderSide(color: Colors.white24, width: 1),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildLandingViewContent() {
    return [
      const SizedBox(height: 8),
      
      // Hero Pledge Banner (The Motive)
      _buildHeroPledgeBanner(),
      const SizedBox(height: 32),
      
      // Access Portals (Who Has to Login)
      _buildAccessPortalsSection(),
      const SizedBox(height: 32),
      
      // Nationwide Presence (Accomplishments / Effects)
      _buildNationwidePresenceSection(),
      const SizedBox(height: 16),
    ];
  }

  Widget _buildHeroPledgeBanner() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFAF8F5), Color(0xFFF1EDE6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      child: LayoutBuilder(
        builder: (context, constraints) {
          bool isWide = constraints.maxWidth > 700;
          
          Widget textColumn = Column(
            crossAxisAlignment: isWide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: isWide ? MainAxisAlignment.start : MainAxisAlignment.center,
                children: const [
                  Icon(Icons.volunteer_activism, color: Color(0xFF8B0000), size: 36),
                  SizedBox(width: 12),
                  Text(
                    'Pledge for',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Voluntary Blood Donation',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF8B0000),
                  letterSpacing: 0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'Join the national movement. Pledge to donate blood voluntarily and help maintain critical reserves across regional blood banks.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      backgroundColor: Color(0xFF8B0000),
                      content: Text('Thank you for taking the Pledge! You are now part of our voluntary donor network.'),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8B0000),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text(
                  'Take Pledge',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ],
          );

          if (isWide) {
            return Row(
              children: [
                Expanded(flex: 3, child: textColumn),
                const SizedBox(width: 24),
                Expanded(
                  flex: 2,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/blood_donation_hero.png',
                      fit: BoxFit.contain,
                      height: 200,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          height: 200,
                          color: const Color(0xFFFAF8F5),
                          alignment: Alignment.center,
                          child: const Icon(Icons.volunteer_activism, size: 80, color: Color(0xFF8B0000)),
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          }

          return Column(
            children: [
              textColumn,
              const SizedBox(height: 24),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  'assets/blood_donation_hero.png',
                  fit: BoxFit.contain,
                  height: 180,
                  errorBuilder: (context, error, stackTrace) {
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAccessPortalsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Access Portals',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Color(0xFF8B0000),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Please select the appropriate portal to sign in or register.',
          style: TextStyle(color: Colors.black54, fontSize: 12),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            double cardWidth = (constraints.maxWidth - 24) / 3;
            bool isMobile = constraints.maxWidth < 650;
            
            List<Widget> portalCards = [
              _buildPortalCard(
                title: 'Voluntary Donors',
                subtitle: 'Find shortages & donate',
                icon: Icons.favorite_border_rounded,
                buttonText: 'Donor Portal',
                onTap: () {
                  setState(() {
                    _currentView = 1;
                    _errorMessage = null;
                    _phoneController.clear();
                    _passwordController.clear();
                  });
                },
              ),
              _buildPortalCard(
                title: 'Blood Centres',
                subtitle: 'Manage inventory & stats',
                icon: Icons.store_rounded,
                buttonText: 'Centre Portal',
                onTap: () {
                  setState(() {
                    _currentView = 2;
                    _errorMessage = null;
                    _phoneController.clear();
                    _passwordController.clear();
                  });
                },
              ),
              _buildPortalCard(
                title: 'Emergency Coordinators',
                subtitle: 'View regional heatmaps',
                icon: Icons.admin_panel_settings_outlined,
                buttonText: 'Coordinator Portal',
                onTap: () {
                  setState(() {
                    _currentView = 5;
                    _errorMessage = null;
                    _phoneController.clear();
                    _passwordController.clear();
                  });
                },
              ),
            ];

            if (isMobile) {
              return Column(
                children: portalCards
                    .map((card) => Padding(
                          padding: const EdgeInsets.only(bottom: 12.0),
                          child: card,
                        ))
                    .toList(),
              );
            }

            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: portalCards
                  .map((card) => SizedBox(width: cardWidth, child: card))
                  .toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildPortalCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required String buttonText,
    required VoidCallback onTap,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 6,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(icon, color: const Color(0xFF8B0000), size: 36),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.black54, fontSize: 11),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: onTap,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8B0000),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(
              buttonText,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCoordinatorPortal() {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: () => setState(() {
            _currentView = 0;
            _errorMessage = null;
          }),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.arrow_back_ios_new_rounded, size: 14, color: Color(0xFF8B0000)),
                SizedBox(width: 8),
                Text(
                  'Back to portals',
                  style: TextStyle(
                    color: Color(0xFF8B0000),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'Emergency Coordinator Sign In',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF8B0000)),
      ),
      const SizedBox(height: 8),
      const Text(
        'Access regional shortage heatmaps, analytics dashboards, and critical alert controls.',
        style: TextStyle(color: Colors.black54, fontSize: 13),
      ),
      const SizedBox(height: 32),
      
      TextField(
        controller: _phoneController,
        decoration: _buildInputDecoration('Coordinator Username / Phone', Icons.admin_panel_settings_outlined),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _passwordController,
        obscureText: true,
        decoration: _buildInputDecoration('Password', Icons.lock_outline),
      ),
      const SizedBox(height: 10),
      LocationPickerField(
        label: 'Operating Region',
        selectedLocation: _searchSelectedLocation,
        onLocationSelected: (loc) {
          setState(() {
            _searchSelectedLocation = loc;
          });
        },
      ),
      const SizedBox(height: 20),
      
      ElevatedButton(
        onPressed: _isVerifying 
            ? null 
            : () => _handleLogin(_phoneController.text, _passwordController.text, 'coordinator'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF8B0000),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _isVerifying
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Text('Login as Coordinator', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
      const SizedBox(height: 16),
      const Center(
        child: Text(
          'Demo Coordinator ID: coordinator | Password: admin123',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ),
    ];
  }

  Widget _buildNationwidePresenceSection() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        key: _presenceKey,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1a0a0a), Color(0xFF3d0000), Color(0xFF5c0a0a)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            // ── Moving blurred background orbs ──────────────────────────
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _bgSlideAnimation,
                builder: (context, child) {
                  final t = _bgSlideAnimation.value;
                  return Stack(
                    children: [
                      // Orb 1 — slides left↔right
                      Positioned(
                        left: -60 + t * 180,
                        top: -40,
                        child: _buildBlurOrb(220, const Color(0xFFCC0000), 0.28),
                      ),
                      // Orb 2 — slides right↔left
                      Positioned(
                        right: -80 + (1 - t) * 160,
                        bottom: -30,
                        child: _buildBlurOrb(260, const Color(0xFF8B0000), 0.22),
                      ),
                      // Orb 3 — slow diagonal drift
                      Positioned(
                        left: 100 + t * 120,
                        bottom: 20 + t * 40,
                        child: _buildBlurOrb(140, const Color(0xFFFF3030), 0.14),
                      ),
                      // Orb 4 — top-right drift
                      Positioned(
                        right: 60 + t * 80,
                        top: 10 + (1 - t) * 50,
                        child: _buildBlurOrb(180, const Color(0xFFFF6060), 0.10),
                      ),
                      // Thin animated grid lines for depth
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _GridLinePainter(t),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            // ── Foreground content ────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Header row ──────────────────────────────────────
                  Row(
                    children: [
                      AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, _) => Opacity(
                          opacity: _pulseAnimation.value,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF4444),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFFF4444).withOpacity(0.7),
                                  blurRadius: 8,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'LIVE NETWORK STATUS',
                        style: TextStyle(
                          color: Color(0xFFFF6666),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Nationwide Presence',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'India\'s largest AI-powered blood intelligence network — connecting 4,500+ centers across 28 states in real time.',
                    style: TextStyle(
                      color: Color(0xFFCCAAAA),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── Animated stat counters ──────────────────────────
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth > 560;
                      final stats = [
                        _StatData(Icons.group_outlined,       '56,04,326', 5604326, 'Registered Donors',     '+12% this year'),
                        _StatData(Icons.local_hospital_outlined, '4,572',  4572,   'Blood Centres',         'All states covered'),
                        _StatData(Icons.event_available_outlined,'2,59,320',259320,'Camps Organised',       'Since 2005'),
                        _StatData(Icons.notifications_active_outlined,'98.2%', null,'Alert Delivery Rate',  'Via FCM + SMS'),
                      ];
                      if (isWide) {
                        return Row(
                          children: stats
                              .map((s) => Expanded(child: Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: _buildAnimatedStatTile(s),
                              )))
                              .toList(),
                        );
                      }
                      return GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 2,
                        childAspectRatio: 1.3,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        children: stats.map((s) => _buildAnimatedStatTile(s)).toList(),
                      );
                    },
                  ),

                  const SizedBox(height: 28),

                  // ── Impact fact strips ──────────────────────────────
                  const Text(
                    'KEY IMPACT METRICS',
                    style: TextStyle(
                      color: Color(0xFFFF6666),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(builder: (ctx, bc) {
                    final isWide = bc.maxWidth > 560;
                    final facts = [
                      _FactData(Icons.bolt,              'Prophet ML + SARIMA',    'Dual-model forecasting engine with <15% MAPE'),
                      _FactData(Icons.radar,             '5 km Proximity Radius',  'Haversine-formula donor ranking in real time'),
                      _FactData(Icons.shield_outlined,   'Zero Data Breach',       'AES-256 encrypted donor PII & consent records'),
                      _FactData(Icons.speed_outlined,    '<3 s Alert Dispatch',    'FCM push + Twilio SMS fallback pipeline'),
                    ];
                    return Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: facts
                          .map((f) => SizedBox(
                                width: isWide
                                    ? (bc.maxWidth - 36) / 2
                                    : bc.maxWidth,
                                child: _buildFactChip(f),
                              ))
                          .toList(),
                    );
                  }),

                  const SizedBox(height: 24),

                  // ── Bottom badge strip ──────────────────────────────
                  Row(
                    children: [
                      _buildBadge(Icons.verified_outlined, 'MoHFW Compliant'),
                      const SizedBox(width: 10),
                      _buildBadge(Icons.security_outlined, 'ISO 27001'),
                      const SizedBox(width: 10),
                      _buildBadge(Icons.workspace_premium_outlined, 'NABH Partner'),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBlurOrb(double size, Color color, double opacity) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(opacity),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(opacity * 0.6),
            blurRadius: size * 0.8,
            spreadRadius: size * 0.2,
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedStatTile(_StatData stat) {
    return AnimatedBuilder(
      animation: _counterAnimation,
      builder: (context, _) {
        String displayValue;
        if (stat.rawValue != null) {
          final animated = (stat.rawValue! * _counterAnimation.value).round();
          if (animated >= 1000000) {
            displayValue = '${(animated / 100000).toStringAsFixed(1)}L';
          } else if (animated >= 1000) {
            displayValue = '${(animated / 1000).toStringAsFixed(1)}K';
          } else {
            displayValue = animated.toString();
          }
        } else {
          displayValue = stat.displayValue;
        }
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFCC0000).withOpacity(0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(stat.icon, color: const Color(0xFFFF6666), size: 16),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                displayValue,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                stat.label,
                style: const TextStyle(color: Color(0xFFCCAAAA), fontSize: 11, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                stat.subLabel,
                style: const TextStyle(color: Color(0xFF996666), fontSize: 10),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFactChip(_FactData fact) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(fact.icon, color: const Color(0xFFFF6666), size: 15),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fact.title,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  fact.description,
                  style: const TextStyle(color: Color(0xFFAA8888), fontSize: 11, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFFFF8888), size: 12),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFFDDBBBB),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  // Legacy _buildStatCard kept for any remaining references
  Widget _buildStatCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF8F5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF8B0000)),
          ),
        ],
      ),
    );
  }

  InputDecoration _buildInputDecoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: const Color(0xFF8B0000)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      labelStyle: const TextStyle(color: Colors.black54),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF8B0000), width: 1.5),
      ),
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
    );
  }

  // --- VIEW 1: DONOR PORTAL (LOGIN / REGISTER CHANGER) ---
  List<Widget> _buildDonorPortal() {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: () => setState(() {
            _currentView = 0;
            _errorMessage = null;
          }),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.arrow_back_ios_new_rounded, size: 14, color: Color(0xFF8B0000)),
                SizedBox(width: 8),
                Text(
                  'Back to portals',
                  style: TextStyle(
                    color: Color(0xFF8B0000),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'Blood Donor Sign In',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF8B0000)),
      ),
      const SizedBox(height: 8),
      const Text(
        'Receive critical local shortage notifications based on your blood group.',
        style: TextStyle(color: Colors.black54, fontSize: 13),
      ),
      const SizedBox(height: 32),
      
      TextField(
        controller: _phoneController,
        keyboardType: TextInputType.phone,
        decoration: _buildInputDecoration('Registered Phone Number', Icons.phone_iphone).copyWith(
          prefixText: '+91 ',
          prefixStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _passwordController,
        obscureText: true,
        decoration: _buildInputDecoration('Password', Icons.lock_outline),
      ),
      const SizedBox(height: 24),
      
      ElevatedButton(
        onPressed: _isVerifying 
            ? null 
            : () => _handleLogin(_phoneController.text, _passwordController.text, 'donor'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF8B0000),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _isVerifying
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Text('Login as Donor', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
      const SizedBox(height: 24),
      
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('New donor? ', style: TextStyle(color: Colors.black87)),
          TextButton(
            onPressed: () {
              setState(() {
                _currentView = 3; // Onboarding Register Form
                _errorMessage = null;
              });
            },
            child: const Text('Register New Account', style: TextStyle(color: Color(0xFF8B0000), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ];
  }

  // --- VIEW 2: ADMIN PORTAL ---
  List<Widget> _buildAdminPortal() {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: () => setState(() {
            _currentView = 0;
            _errorMessage = null;
          }),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.arrow_back_ios_new_rounded, size: 14, color: Color(0xFF8B0000)),
                SizedBox(width: 8),
                Text(
                  'Back to portals',
                  style: TextStyle(
                    color: Color(0xFF8B0000),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'Blood Bank Manager Login',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF8B0000)),
      ),
      const SizedBox(height: 8),
      const Text(
        'Access inventory dashboards, Prophet forecasting reports, and donor nudges.',
        style: TextStyle(color: Colors.black54, fontSize: 13),
      ),
      const SizedBox(height: 32),
      
      TextField(
        controller: _phoneController,
        decoration: _buildInputDecoration('Admin Username / Phone', Icons.admin_panel_settings_outlined),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _passwordController,
        obscureText: true,
        decoration: _buildInputDecoration('Password', Icons.lock_outline),
      ),
      const SizedBox(height: 24),
      
      ElevatedButton(
        onPressed: _isVerifying 
            ? null 
            : () => _handleLogin(_phoneController.text, _passwordController.text, 'bank_admin'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF8B0000),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _isVerifying
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Text('Login as Admin', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
      const SizedBox(height: 16),
      Center(
        child: Text(
          'Demo Admin ID: admin | Password: admin123',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ),
      const SizedBox(height: 16),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('New blood bank? ', style: TextStyle(color: Colors.black87)),
          TextButton(
            onPressed: () {
              setState(() {
                _currentView = 4;
                _errorMessage = null;
              });
            },
            child: const Text('Register Blood Bank', style: TextStyle(color: Color(0xFF8B0000), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ];
  }

  // --- VIEW 3: DONOR REGISTRATION FORM ---
  List<Widget> _buildDonorRegistrationForm() {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: () => setState(() {
            _currentView = 1;
            _errorMessage = null;
          }),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.arrow_back_ios_new_rounded, size: 14, color: Color(0xFF8B0000)),
                SizedBox(width: 8),
                Text(
                  'Back to Donor Login',
                  style: TextStyle(
                    color: Color(0xFF8B0000),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'Create Donor Account',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF8B0000)),
      ),
      const SizedBox(height: 8),
      const Text(
        'Enter details to register and verify nearby blood shortages.',
        style: TextStyle(color: Colors.black54, fontSize: 13),
      ),
      const SizedBox(height: 24),
      
      // Personal details
      TextField(
        controller: _regNameController,
        decoration: _buildInputDecoration('Full Name', Icons.person_outline),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _regPhoneController,
        keyboardType: TextInputType.phone,
        decoration: _buildInputDecoration('Mobile Number', Icons.phone_iphone).copyWith(
          prefixText: '+91 ',
          prefixStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _regPasswordController,
        obscureText: true,
        decoration: _buildInputDecoration('Create Password', Icons.lock_outline).copyWith(
          helperText: 'Minimum 8 characters, must include at least 1 number.',
          helperStyle: const TextStyle(color: Colors.black54, fontSize: 11),
        ),
      ),
      const SizedBox(height: 10),
      
      // Blood Group & Area/Region Row
      DropdownButtonFormField<String>(
        value: _regSelectedBloodGroup,
        decoration: _buildInputDecoration('Blood Group', Icons.bloodtype_outlined),
        items: ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']
            .map((g) => DropdownMenuItem(value: g, child: Text(g, style: const TextStyle(color: Colors.black87))))
            .toList(),
        onChanged: (val) {
          if (val != null) setState(() => _regSelectedBloodGroup = val);
        },
      ),
      const SizedBox(height: 10),
      LocationPickerField(
        label: 'Area / Region',
        selectedLocation: _regSelectedLocation,
        onLocationSelected: (loc) {
          setState(() {
            _regSelectedLocation = loc;
            _regCityController.text = loc?.name ?? '';
          });
        },
      ),
      const SizedBox(height: 10),
      
    // Date of Birth DatePicker
    GestureDetector(
      onTap: () async {
        final date = await showDatePicker(
          context: context,
          initialDate: _regSelectedDob,
          firstDate: DateTime(1960),
          lastDate: DateTime.now().subtract(const Duration(days: 15 * 365)),
        );
        if (date != null) setState(() => _regSelectedDob = date);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.calendar_month, color: Color(0xFF8B0000)),
                const SizedBox(width: 12),
                Text(
                  'Date of Birth: ${_regSelectedDob.toLocal().toIso8601String().split('T')[0]}',
                  style: const TextStyle(fontSize: 16, color: Colors.black87),
                ),
              ],
            ),
            const Icon(Icons.arrow_drop_down, color: Color(0xFF8B0000)),
          ],
        ),
      ),
    ),
    const SizedBox(height: 8),

    // Display dynamically calculated Age
    Builder(
      builder: (context) {
        int calculatedAge = _calculateAge(_regSelectedDob);
        bool isEligible = calculatedAge >= 15;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 4.0),
          child: Row(
            children: [
              Icon(
                isEligible ? Icons.check_circle : Icons.error,
                color: isEligible ? const Color(0xFF389E0D) : const Color(0xFFCF1322),
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                'Age: $calculatedAge Years ${isEligible ? "(Eligible)" : "(Underage - Blocked)"}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: isEligible ? const Color(0xFF389E0D) : const Color(0xFFCF1322),
                ),
              ),
            ],
          ),
        );
      }
    ),
    const SizedBox(height: 10),

    // ID Document Upload Dropzone Card
    Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _selectedIdDocument != null ? const Color(0xFF389E0D).withOpacity(0.5) : const Color(0xFFE2E8F0),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.cloud_upload_outlined,
                color: _selectedIdDocument != null ? const Color(0xFF389E0D) : Colors.grey,
              ),
              const SizedBox(width: 12),
              const Text(
                'Upload Identity Document',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Aadhaar Card, Driving License, or Passport (Required)',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          if (_selectedIdDocument != null) ...[
            Row(
              children: [
                const Icon(Icons.insert_drive_file, color: Color(0xFF389E0D), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final name = _selectedIdDocument!.name;
                      final maskedName = name.length > 4 
                          ? '***${name.substring(name.length - 4)}' 
                          : name;
                      return Text(
                        maskedName,
                        style: const TextStyle(fontSize: 13, color: Color(0xFF389E0D), overflow: TextOverflow.ellipsis),
                      );
                    }
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _selectedIdDocument = null),
                  child: const Text('Remove', style: TextStyle(color: Colors.red, fontSize: 13)),
                ),
              ],
            ),
          ] else ...[
            OutlinedButton(
              onPressed: () async {
                final file = await FilePickerHelper.pickFile();
                if (file != null) {
                  setState(() {
                    _selectedIdDocument = file;
                    _errorMessage = null;
                  });
                }
              },
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF8B0000)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text(
                'Choose File',
                style: TextStyle(color: Color(0xFF8B0000), fontSize: 13),
              ),
            ),
          ],
        ],
      ),
    ),
    const SizedBox(height: 12),
    
    // Location permission toggle
    SwitchListTile(
      title: const Text('GPS Proximity Access', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
      subtitle: const Text('Required to match nearest blood bank shortages'),
      value: _regLocationPermission,
      activeColor: const Color(0xFF8B0000),
      onChanged: (val) => setState(() => _regLocationPermission = val),
    ),
    const SizedBox(height: 12),

    // DPDP Act 2023 Consent Checkbox
    CheckboxListTile(
      title: const Text(
        'DPDP Act 2023 Compliance Consent',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87),
      ),
      subtitle: const Text(
        'I consent to securely uploading my identity document (Aadhaar/License) for verification. '
        'My sensitive data will be encrypted and stored in compliance with the DPDP Act 2023.',
        style: TextStyle(fontSize: 11, color: Colors.black54),
      ),
      value: _regConsentGiven,
      activeColor: const Color(0xFF8B0000),
      controlAffinity: ListTileControlAffinity.leading,
      onChanged: (val) => setState(() => _regConsentGiven = val ?? false),
    ),
    const SizedBox(height: 24),
      
      ElevatedButton(
        onPressed: _isVerifying ? null : _handleRegister,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF8B0000),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _isVerifying
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Text('Complete Registration', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    ];
  }

  // --- VIEW 4: ADMIN (BLOOD BANK) REGISTRATION FORM ---
  List<Widget> _buildAdminRegistrationForm() {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: () => setState(() {
            _currentView = 2;
            _errorMessage = null;
          }),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.arrow_back_ios_new_rounded, size: 14, color: Color(0xFF8B0000)),
                SizedBox(width: 8),
                Text(
                  'Back to Admin Login',
                  style: TextStyle(
                    color: Color(0xFF8B0000),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'Register Blood Bank',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF8B0000)),
      ),
      const SizedBox(height: 8),
      const Text(
        'Onboard your blood bank and upload inventory databases to start Prophet ML calculations.',
        style: TextStyle(color: Colors.black54, fontSize: 13),
      ),
      const SizedBox(height: 24),
      
      TextField(
        controller: _adminRegNameController,
        decoration: _buildInputDecoration('Blood Bank Official Name', Icons.domain_outlined),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _adminRegPhoneController,
        keyboardType: TextInputType.phone,
        decoration: _buildInputDecoration('Official Contact Mobile / Username', Icons.phone_iphone).copyWith(
          prefixText: '+91 ',
          prefixStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _adminRegPasswordController,
        obscureText: true,
        decoration: _buildInputDecoration('Create Password', Icons.lock_outline).copyWith(
          helperText: 'Minimum 8 characters, must include at least 1 number.',
          helperStyle: const TextStyle(color: Colors.black54, fontSize: 11),
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _adminRegAddressController,
        decoration: _buildInputDecoration('Complete Postal Address', Icons.map_outlined),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _adminRegWebsiteController,
        keyboardType: TextInputType.url,
        decoration: _buildInputDecoration('Official Website Link (e.g. https://...)', Icons.language_outlined),
      ),
      const SizedBox(height: 10),
      
      LocationPickerField(
        label: 'Operating Region',
        selectedLocation: _adminRegSelectedLocation,
        onLocationSelected: (loc) {
          setState(() {
            _adminRegSelectedLocation = loc;
          });
        },
      ),
      const SizedBox(height: 10),
      GestureDetector(
        onTap: () async {
          final date = await showDatePicker(
            context: context,
            initialDate: _adminRegSelectedEstDate,
            firstDate: DateTime(1900),
            lastDate: DateTime.now(),
          );
          if (date != null) setState(() => _adminRegSelectedEstDate = date);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.calendar_month, color: Color(0xFF8B0000)),
                  const SizedBox(width: 12),
                  Text(
                    'Established: ${_adminRegSelectedEstDate.toLocal().toIso8601String().split('T')[0]}',
                    style: const TextStyle(fontSize: 16, color: Colors.black87),
                  ),
                ],
              ),
              const Icon(Icons.arrow_drop_down, color: Color(0xFF8B0000)),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),

      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _adminRegSelectedDoc != null ? const Color(0xFF389E0D).withOpacity(0.5) : const Color(0xFFE2E8F0),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.verified_user_outlined,
                  color: _adminRegSelectedDoc != null ? const Color(0xFF389E0D) : Colors.grey,
                ),
                const SizedBox(width: 12),
                const Text(
                  'Upload Licensing Document',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Govt Blood Bank License or NABL Approval PDF/Image/Word/CSV/JSON (Required)',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            if (_adminRegSelectedDoc != null) ...[
              Row(
                children: [
                  const Icon(Icons.insert_drive_file, color: Color(0xFF389E0D), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _adminRegSelectedDoc!.name,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF389E0D), overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _adminRegSelectedDoc = null),
                    child: const Text('Remove', style: TextStyle(color: Colors.red, fontSize: 13)),
                  ),
                ],
              ),
            ] else ...[
              OutlinedButton(
                onPressed: () async {
                  final file = await FilePickerHelper.pickFile();
                  if (file != null) {
                    setState(() {
                      _adminRegSelectedDoc = file;
                      _errorMessage = null;
                    });
                  }
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF8B0000)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text(
                  'Choose License File',
                  style: TextStyle(color: Color(0xFF8B0000), fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),

      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _adminRegSelectedDatabaseFile != null ? const Color(0xFF389E0D).withOpacity(0.5) : const Color(0xFFE2E8F0),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.storage_rounded,
                  color: _adminRegSelectedDatabaseFile != null ? const Color(0xFF389E0D) : Colors.grey,
                ),
                const SizedBox(width: 12),
                const Text(
                  'Upload Donations & Inventory DB',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Upload CSV or JSON of past 1 year donations, transfusions, and current stocks (Required)',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            if (_adminRegSelectedDatabaseFile != null) ...[
              Row(
                children: [
                  const Icon(Icons.analytics_outlined, color: Color(0xFF389E0D), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _adminRegSelectedDatabaseFile!.name,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF389E0D), overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _adminRegSelectedDatabaseFile = null),
                    child: const Text('Remove', style: TextStyle(color: Colors.red, fontSize: 13)),
                  ),
                ],
              ),
            ] else ...[
              OutlinedButton(
                onPressed: () async {
                  final file = await FilePickerHelper.pickFile();
                  if (file != null) {
                    setState(() {
                      _adminRegSelectedDatabaseFile = file;
                      _errorMessage = null;
                    });
                  }
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF8B0000)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text(
                  'Choose Database File',
                  style: TextStyle(color: Color(0xFF8B0000), fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),

      // DPDP Act 2023 Consent Checkbox
      CheckboxListTile(
        title: const Text(
          'DPDP Act 2023 Consent & Compliance',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87),
        ),
        subtitle: const Text(
          'We consent to securely upload our blood bank license and inventory data. '
          'Our database information will be stored securely and encrypted in compliance with the DPDP Act 2023.',
          style: TextStyle(fontSize: 11, color: Colors.black54),
        ),
        value: _adminRegConsentGiven,
        activeColor: const Color(0xFF8B0000),
        controlAffinity: ListTileControlAffinity.leading,
        onChanged: (val) => setState(() => _adminRegConsentGiven = val ?? false),
      ),
      const SizedBox(height: 24),
      
      ElevatedButton(
        onPressed: _isVerifying ? null : _handleAdminRegister,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF8B0000),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _isVerifying
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Text('Complete Blood Bank Setup', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    ];
  }

  List<Map<String, dynamic>> _parseInventoryFromJson(String jsonText, String registeredName) {
    final List<Map<String, dynamic>> parsedList = [];
    try {
      final decoded = json.decode(jsonText);
      if (decoded is List) {
        for (var item in decoded) {
          if (item is Map) {
            final String? bg = item['blood_group']?.toString();
            final double? units = double.tryParse(item['units_available']?.toString() ?? item['units']?.toString() ?? '0');
            final double? expiring = double.tryParse(item['units_expiring_3days']?.toString() ?? '0');
            if (bg != null && units != null) {
              parsedList.add({
                'blood_group': bg,
                'units': units,
                'units_expiring_3days': expiring ?? 0.0,
              });
            }
          }
        }
      } else if (decoded is Map) {
        if (decoded['inventory'] is List) {
          for (var item in decoded['inventory']) {
            if (item is Map) {
              final String? bg = item['blood_group']?.toString();
              final double? units = double.tryParse(item['units_available']?.toString() ?? item['units']?.toString() ?? '0');
              final double? expiring = double.tryParse(item['units_expiring_3days']?.toString() ?? '0');
              if (bg != null && units != null) {
                parsedList.add({
                  'blood_group': bg,
                  'units': units,
                  'units_expiring_3days': expiring ?? 0.0,
                });
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Error parsing JSON inventory: $e");
    }
    return parsedList;
  }

  List<String> _splitCsvRow(String row) {
    final List<String> result = [];
    bool inQuotes = false;
    StringBuffer currentToken = StringBuffer();

    for (int i = 0; i < row.length; i++) {
      final char = row[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        result.add(currentToken.toString().trim().replaceAll('"', ''));
        currentToken.clear();
      } else {
        currentToken.write(char);
      }
    }
    result.add(currentToken.toString().trim().replaceAll('"', ''));
    return result;
  }

  List<Map<String, dynamic>> _parseInventoryFromCsv(String csvText, String registeredName) {
    final List<Map<String, dynamic>> parsedList = [];
    try {
      final lines = csvText.split('\n');
      if (lines.isEmpty) return parsedList;

      final headerLine = lines.first.trim();
      final headers = _splitCsvRow(headerLine);
      
      int bankNameIdx = headers.indexOf('bank_name');
      int bgIdx = headers.indexOf('blood_group');
      int unitsIdx = headers.indexOf('units_available');
      if (unitsIdx == -1) unitsIdx = headers.indexOf('units');
      int expiringIdx = headers.indexOf('units_expiring_3days');

      if (bgIdx == -1 || unitsIdx == -1) {
        return parsedList;
      }

      final Map<String, List<Map<String, dynamic>>> bankGroups = {};

      for (int i = 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        
        final cols = _splitCsvRow(line);
        if (cols.length <= bgIdx || cols.length <= unitsIdx) continue;

        final String csvBankName = bankNameIdx != -1 && cols.length > bankNameIdx ? cols[bankNameIdx] : "Default Bank";
        final String bg = cols[bgIdx];
        final double units = double.tryParse(cols[unitsIdx]) ?? 0.0;
        final double expiring = expiringIdx != -1 && cols.length > expiringIdx ? (double.tryParse(cols[expiringIdx]) ?? 0.0) : 0.0;

        final entry = {
          'blood_group': bg,
          'units': units,
          'units_expiring_3days': expiring,
        };

        bankGroups.putIfAbsent(csvBankName, () => []).add(entry);
      }

      String? bestMatchBankName;
      for (var name in bankGroups.keys) {
        if (name.toLowerCase().contains(registeredName.toLowerCase()) || 
            registeredName.toLowerCase().contains(name.toLowerCase())) {
          bestMatchBankName = name;
          break;
        }
      }

      if (bestMatchBankName != null) {
        parsedList.addAll(bankGroups[bestMatchBankName]!);
        debugPrint("Found matching bank in CSV: $bestMatchBankName");
      } else if (bankGroups.isNotEmpty) {
        final firstKey = bankGroups.keys.first;
        parsedList.addAll(bankGroups[firstKey]!);
        debugPrint("No matching bank found in CSV. Falling back to first bank: $firstKey");
      }
    } catch (e) {
      debugPrint("Error parsing CSV inventory: $e");
    }
    return parsedList;
  }

  List<Map<String, dynamic>> _parseUploadedInventory(PickedFile file, String registeredName) {
    try {
      final decodedBytes = base64.decode(file.base64Content);
      final plainText = utf8.decode(decodedBytes);
      
      if (file.name.toLowerCase().endsWith('.json')) {
        final parsed = _parseInventoryFromJson(plainText, registeredName);
        if (parsed.isNotEmpty) return parsed;
      } else {
        final parsed = _parseInventoryFromCsv(plainText, registeredName);
        if (parsed.isNotEmpty) return parsed;
      }
    } catch (e) {
      debugPrint("Error decoding or parsing uploaded database: $e");
    }
    return [];
  }

  Future<void> _handleAdminRegister() async {
    if (_adminRegSelectedLocation == null) {
      setState(() => _errorMessage = "Please select an Operating Region.");
      return;
    }

    if (_adminRegNameController.text.isEmpty ||
        _adminRegPhoneController.text.isEmpty ||
        _adminRegPasswordController.text.isEmpty ||
        _adminRegAddressController.text.isEmpty) {
      setState(() => _errorMessage = "Please fill in all details.");
      return;
    }

    final String fullPhone = '+91${_adminRegPhoneController.text.trim()}';
    final phoneRegex = RegExp(r"^\+91[6-9]\d{9}$");
    if (!phoneRegex.hasMatch(fullPhone)) {
      setState(() => _errorMessage = "Phone number must be in format +91 followed by 10 digits starting with 6-9.");
      return;
    }

    final passwordRegex = RegExp(r"^(?=.*[0-9]).{8,}$");
    if (!passwordRegex.hasMatch(_adminRegPasswordController.text)) {
      setState(() => _errorMessage = "Password must be at least 8 characters long and contain at least one digit.");
      return;
    }

    if (_adminRegSelectedDoc == null) {
      setState(() => _errorMessage = "Approval verification document is required.");
      return;
    }

    if (_adminRegSelectedDatabaseFile == null) {
      setState(() => _errorMessage = "Historical database and inventory file upload is required.");
      return;
    }

    if (!_adminRegConsentGiven) {
      setState(() => _errorMessage = "You must give consent under DPDP Act 2023 to register.");
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorMessage = null;
    });

    final state = Provider.of<AppState>(context, listen: false);

    // Map selected region to standard coordinate centers from IndiaLocation list
    final location = _adminRegSelectedLocation!;
    double lat = location.latitude;
    double lng = location.longitude;

    final seconds = DateTime.now().second;
    lat += (0.012 * ((seconds % 4) - 2));
    lng += (0.012 * ((seconds % 3) - 1));

    // Parse uploaded database file if present
    List<Map<String, dynamic>> inventoryData = [];
    if (_adminRegSelectedDatabaseFile != null) {
      inventoryData = _parseUploadedInventory(
        _adminRegSelectedDatabaseFile!,
        _adminRegNameController.text.trim(),
      );
    }

    // Fallback if parsing failed or was empty
    if (inventoryData.isEmpty) {
      inventoryData = [
        {'blood_group': 'O+', 'units': 12.5 + _randomJitter(5.0), 'units_expiring_3days': 1.0},
        {'blood_group': 'O-', 'units': 4.0 + _randomJitter(3.0), 'units_expiring_3days': 0.5},
        {'blood_group': 'A+', 'units': 15.0 + _randomJitter(5.0), 'units_expiring_3days': 1.0},
        {'blood_group': 'A-', 'units': 4.5 + _randomJitter(3.0), 'units_expiring_3days': 0.5},
        {'blood_group': 'B+', 'units': 14.0 + _randomJitter(5.0), 'units_expiring_3days': 1.0},
        {'blood_group': 'B-', 'units': 6.0 + _randomJitter(3.0), 'units_expiring_3days': 0.5},
        {'blood_group': 'AB+', 'units': 8.0 + _randomJitter(4.0), 'units_expiring_3days': 0.5},
        {'blood_group': 'AB-', 'units': 2.0 + _randomJitter(2.0), 'units_expiring_3days': 0.2},
      ];
    }

    try {
      final createdBank = await AuthService.instance.registerBloodBank(
        name: _adminRegNameController.text.trim(),
        phone: fullPhone,
        password: _adminRegPasswordController.text,
        address: _adminRegAddressController.text.trim(),
        estDate: _adminRegSelectedEstDate.toIso8601String().split('T')[0],
        lat: lat,
        lng: lng,
        regionName: _adminRegSelectedLocation!.name,
        website: _adminRegWebsiteController.text.trim(),
        approvalDocBase64: _adminRegSelectedDoc?.base64Content,
        approvalDocName: _adminRegSelectedDoc?.name,
        inventoryData: inventoryData,
      );

      final uid = createdBank['admin_user_id'];
      final profile = {
        'name': createdBank['name'],
        'contact_phone': createdBank['contact_phone'],
        'address': createdBank['address'],
        'bank_id': createdBank['bank_id'],
        'city': _adminRegSelectedLocation!.name,
      };
      final token = 'mock_jwt_token_bank_${createdBank['bank_id']}';
      await state.login('bank_admin', uid, profile, token: token);
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isVerifying = false;
      });
    }
  }

  double _randomJitter(double maxVal) {
    return (DateTime.now().millisecond % 100) / 100.0 * maxVal;
  }
}

// ── Data models for the Nationwide Presence section ───────────────────────────

class _StatData {
  final IconData icon;
  final String displayValue;
  final int? rawValue; // null means display static text (e.g. percentages)
  final String label;
  final String subLabel;
  const _StatData(this.icon, this.displayValue, this.rawValue, this.label, this.subLabel);
}

class _FactData {
  final IconData icon;
  final String title;
  final String description;
  const _FactData(this.icon, this.title, this.description);
}

// ── Animated subtle grid line painter ─────────────────────────────────────────

class _GridLinePainter extends CustomPainter {
  final double t; // 0.0 → 1.0 animation progress

  _GridLinePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF).withOpacity(0.04)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    const spacing = 48.0;
    final offset = t * spacing; // horizontal scroll offset

    // Vertical lines
    for (double x = -spacing + offset; x < size.width + spacing; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    // Horizontal lines
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Diagonal accent lines
    final diag = Paint()
      ..color = const Color(0xFFFF4444).withOpacity(0.04)
      ..strokeWidth = 1.0;

    final startX = -size.height + offset * 2;
    for (double x = startX; x < size.width + size.height; x += spacing * 3) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), diag);
    }
  }

  @override
  bool shouldRepaint(_GridLinePainter oldDelegate) => oldDelegate.t != t;
}
