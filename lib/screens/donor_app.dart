import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:math';
import '../main.dart';
import '../utils/geolocation_helper.dart';
import '../data/local_db.dart';
import '../services/bssi_service.dart';

class DonorHomeScreen extends StatefulWidget {
  const DonorHomeScreen({super.key});

  @override
  State<DonorHomeScreen> createState() => _DonorHomeScreenState();
}

class _DonorHomeScreenState extends State<DonorHomeScreen> {
  int _currentTab = 0;
  bool _isLoading = false;
  Map<String, dynamic> _donorStats = {
    'eligibility_status': true,
    'eligible_in_days': 0,
    'last_donation_date': null,
    'total_donations': 0,
    'donations_history': [],
  };
  Map<String, dynamic>? _dashboardData;

  int _currentPollIntervalSeconds = 15;
  String _lastCautionLevel = '';

  @override
  void initState() {
    super.initState();
    _fetchDonorData();
    _fetchDashboardData();
    _startGpsAndAlertsPolling();
  }

  void _startGpsAndAlertsPolling() {
    // NOTE: This 15s polling loop is a temporary local simulation placeholder
    // for the production Firebase Cloud Messaging (FCM) push notification architecture.
    // We implement exponential backoff to reduce backend hammer frequency.
    Future.delayed(const Duration(seconds: 1), _pollTick);
  }

  void _resetPollingInterval() {
    _currentPollIntervalSeconds = 15;
  }

  Future<void> _pollTick() async {
    if (!mounted) return;
    await _syncGpsAndFetchAlerts();
    
    final currentCaution = _dashboardData != null ? _dashboardData!['caution_level'] : '';
    if (currentCaution == _lastCautionLevel) {
      _currentPollIntervalSeconds = (_currentPollIntervalSeconds * 1.5).toInt();
      if (_currentPollIntervalSeconds > 120) {
        _currentPollIntervalSeconds = 120;
      }
      print("Polling backoff: interval increased to $_currentPollIntervalSeconds seconds.");
    } else {
      _currentPollIntervalSeconds = 15;
      _lastCautionLevel = currentCaution;
    }
    
    Future.delayed(Duration(seconds: _currentPollIntervalSeconds), _pollTick);
  }

  Future<_GPSCoords?> _getCurrentCoordinatesFallback() async {
    final coords = await GeolocationHelper.getCurrentLocation();
    if (coords != null) return _GPSCoords(coords.latitude, coords.longitude);
    return null;
  }

  Future<void> _syncGpsAndFetchAlerts() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (state.donorId == null || state.firebaseUid == null) return;

    // 1. Geolocation Sync
    final coords = await _getCurrentCoordinatesFallback();
    if (coords != null) {
      print("Live Browser GPS Coordinates: Lat=${coords.latitude}, Lng=${coords.longitude}");
      try {
        await LocalDatabase.instance.init();
        await LocalDatabase.instance.update(
          'donors', 
          'donor_id', 
          state.donorId!, 
          {
            'location_lat': coords.latitude,
            'location_lng': coords.longitude,
          }
        );
      } catch (e) {
        print("Error updating live location: $e");
      }
    }

    // 2. Refresh Dashboard Data
    await _fetchDashboardData();

    // 3. Check for Shortage alerts
    if (_dashboardData != null) {
      final cautionLevel = _dashboardData!['caution_level'];
      if ((cautionLevel == 'CRITICAL' || cautionLevel == 'WARNING') && state.pendingNotification == null) {
        try {
          final donorRows = LocalDatabase.instance.getTable('donors').where((d) => d['donor_id'] == state.donorId).toList();
          if (donorRows.isEmpty) return;
          final donor = donorRows.first;
          final String bg = donor['blood_group'];
          
          final alerts = LocalDatabase.instance.getTable('shortage_alerts')
              .where((a) => a['blood_group'] == bg)
              .toList();
          
          if (alerts.isNotEmpty) {
            alerts.sort((a, b) => (b['triggered_at'] as String).compareTo(a['triggered_at'] as String));
            final latestAlert = alerts.first;
            final int bankId = latestAlert['bank_id'] as int;
            
            final bank = LocalDatabase.instance.getTable('blood_banks').firstWhere((b) => b['bank_id'] == bankId);
            
            final double donorLat = (donor['location_lat'] as num).toDouble();
            final double donorLng = (donor['location_lng'] as num).toDouble();
            final double bankLat = (bank['location_lat'] as num).toDouble();
            final double bankLng = (bank['location_lng'] as num).toDouble();
            final double dist = BssiService.instance.calculateDistance(donorLat, donorLng, bankLat, bankLng);
            final int eta = (dist * 2).toInt() + 5;
            
            final alertPayload = {
              'log_id': 999,
              'alert_id': latestAlert['alert_id'],
              'bank_name': bank['name'],
              'bank_address': bank['address'],
              'blood_group': bg,
              'bssi': latestAlert['bssi_at_trigger'],
              'distance_km': double.parse(dist.toStringAsFixed(2)),
              'eta_minutes': eta,
              'bank_lat': bankLat,
              'bank_lng': bankLng,
              'user_start_lat': donorLat,
              'user_start_lng': donorLng,
              'message': 'CRITICAL SHORTAGE: ${bg} needed at ${bank['name']} immediately!'
            };
            state.triggerMockNotification(alertPayload);
          }
        } catch (e) {
          print("Error auto-matching nearest shortage: $e");
        }
      }
    }
  }


  Future<void> _fetchDonorData() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (state.donorId == null) return;
    
    setState(() => _isLoading = true);
    
    try {
      await LocalDatabase.instance.init();
      final donationRecords = LocalDatabase.instance.getTable('donation_records')
          .where((d) => d['donor_id'] == state.donorId)
          .toList();
      
      final List<Map<String, dynamic>> history = [];
      final banks = LocalDatabase.instance.getTable('blood_banks');
      for (var rec in donationRecords) {
        final bank = banks.firstWhere((b) => b['bank_id'] == rec['bank_id'], orElse: () => {});
        history.add({
          'record_id': rec['record_id'],
          'donated_at': rec['donated_at'],
          'units': (rec['units'] as num).toDouble(),
          'blood_group': rec['blood_group'],
          'bank_name': bank.isNotEmpty ? bank['name'] : 'Local Blood Bank',
        });
      }
      history.sort((a, b) => (b['donated_at'] as String).compareTo(a['donated_at'] as String));
      
      // Calculate eligibility
      bool isEligible = true;
      int eligibleInDays = 0;
      DateTime? lastDonation;
      
      if (history.isNotEmpty) {
        final lastDateStr = history.first['donated_at'];
        lastDonation = DateTime.parse(lastDateStr);
        final daysSince = DateTime.now().difference(lastDonation).inDays;
        if (daysSince < 90) {
          isEligible = false;
          eligibleInDays = 90 - daysSince;
        }
      }
      
      setState(() {
        _donorStats = {
          'eligibility_status': isEligible,
          'eligible_in_days': eligibleInDays,
          'last_donation_date': lastDonation,
          'total_donations': history.length,
          'donations_history': history,
        };
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      print("Error loading donor data: $e");
    }
  }

  Future<void> _fetchDashboardData() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (state.donorId == null) return;
    
    try {
      await LocalDatabase.instance.init();
      
      final donorRows = LocalDatabase.instance.getTable('donors').where((d) => d['donor_id'] == state.donorId).toList();
      if (donorRows.isEmpty) return;
      final donor = donorRows.first;
      final String bg = donor['blood_group'];
      final double donorLat = (donor['location_lat'] as num).toDouble();
      final double donorLng = (donor['location_lng'] as num).toDouble();
      
      await BssiService.instance.updateAllBssiScores();
      
      final allBanks = LocalDatabase.instance.getTable('blood_banks');
      final allBssi = LocalDatabase.instance.getTable('bssi_scores');
      final allInv = LocalDatabase.instance.getTable('blood_inventory');
      
      final List<Map<String, dynamic>> banksList = [];
      double highestBssi = 0.0;
      
      for (var bank in allBanks) {
        final int bId = bank['bank_id'] as int;
        final bssiRow = allBssi.firstWhere((s) => s['bank_id'] == bId && s['blood_group'] == bg, orElse: () => {});
        final double bssi = bssiRow.isNotEmpty ? (bssiRow['score'] as num).toDouble() : 20.0;
        
        if (bssi > highestBssi) highestBssi = bssi;
        
        final invRow = allInv.firstWhere((i) => i['bank_id'] == bId && i['blood_group'] == bg, orElse: () => {});
        final double units = invRow.isNotEmpty ? (invRow['units_available'] as num).toDouble() : 0.0;
        
        final double dist = BssiService.instance.calculateDistance(donorLat, donorLng, (bank['location_lat'] as num).toDouble(), (bank['location_lng'] as num).toDouble());
        final int eta = (dist * 2).toInt() + 5;
        
        banksList.add({
          'bank_id': bId,
          'bank_name': bank['name'],
          'address': bank['address'],
          'bssi': bssi,
          'units_available': units,
          'distance_km': double.parse(dist.toStringAsFixed(2)),
          'eta_minutes': eta,
          'phone': bank['contact_phone'],
          'location_lat': (bank['location_lat'] as num).toDouble(),
          'location_lng': (bank['location_lng'] as num).toDouble(),
        });
      }
      
      banksList.sort((a, b) => (a['distance_km'] as num).compareTo(b['distance_km'] as num));
      
      String cautionLevel = 'NORMAL';
      String cautionMessage = 'Blood levels for ${bg} are currently stable in your area. Keep monitoring.';
      if (highestBssi > 75.0) {
        cautionLevel = 'CRITICAL';
        cautionMessage = 'CRITICAL shortage of ${bg} detected in your region! Immediate donations needed.';
      } else if (highestBssi > 55.0) {
        cautionLevel = 'WARNING';
        cautionMessage = 'Warning: Stock levels of ${bg} are falling. Consider scheduling a donation soon.';
      }
      
      setState(() {
        _dashboardData = {
          'caution_level': cautionLevel,
          'caution_message': cautionMessage,
          'banks': banksList.take(5).toList(),
          'dob': donor['dob'],
          'id_document_name': donor['id_document_name'],
        };
      });
    } catch (e) {
      print("Error fetching donor dashboard data: $e");
    }
  }

  Future<void> _triggerMockMobilizationForBank(Map<String, dynamic> bank) async {
    final state = Provider.of<AppState>(context, listen: false);
    setState(() => _isLoading = true);
    
    try {
      await LocalDatabase.instance.init();
      
      final int bId = bank['bank_id'] as int;
      final newAlert = {
        'bank_id': bId,
        'blood_group': state.bloodGroup,
        'bssi_at_trigger': bank['bssi'],
        'donors_notified': 300,
        'donors_responded': 0,
        'response_rate': 0.0,
        'triggered_at': DateTime.now().toIso8601String(),
      };
      await LocalDatabase.instance.insert('shortage_alerts', newAlert, 'alert_id');

      final donorRows = LocalDatabase.instance.getTable('donors').where((d) => d['donor_id'] == state.donorId).toList();
      final double userLat = donorRows.isNotEmpty ? (donorRows.first['location_lat'] as num).toDouble() : 13.0494;
      final double userLng = donorRows.isNotEmpty ? (donorRows.first['location_lng'] as num).toDouble() : 80.2104;
      
      final mockNotif = {
        'log_id': 999,
        'alert_id': 999,
        'bank_name': bank['bank_name'],
        'bank_address': bank['address'],
        'blood_group': state.bloodGroup,
        'bssi': bank['bssi'],
        'distance_km': bank['distance_km'],
        'eta_minutes': bank['eta_minutes'],
        'phone': bank['phone'] ?? '+919999000000',
        'bank_lat': bank['location_lat'],
        'bank_lng': bank['location_lng'],
        'user_start_lat': userLat,
        'user_start_lng': userLng,
      };
      setState(() => _isLoading = false);
      state.triggerMockNotification(mockNotif);
    } catch (e) {
      setState(() => _isLoading = false);
      print("Error triggering mock mobilization: $e");
    }
  }

  Future<void> _simulateMockPushNotification(AppState state) async {
    if (state.donorId == null) return;
    setState(() => _isLoading = true);
    
    try {
      await LocalDatabase.instance.init();
      
      final donorRows = LocalDatabase.instance.getTable('donors').where((d) => d['donor_id'] == state.donorId).toList();
      if (donorRows.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }
      
      final donor = donorRows.first;
      final String bg = donor['blood_group'];
      final double donorLat = (donor['location_lat'] as num).toDouble();
      final double donorLng = (donor['location_lng'] as num).toDouble();
      
      final allBanks = LocalDatabase.instance.getTable('blood_banks');
      double minDistance = double.infinity;
      Map<String, dynamic>? closestBank;
      
      for (var bank in allBanks) {
        final double dist = BssiService.instance.calculateDistance(
          donorLat,
          donorLng,
          (bank['location_lat'] as num).toDouble(),
          (bank['location_lng'] as num).toDouble(),
        );
        if (dist < minDistance) {
          minDistance = dist;
          closestBank = bank;
        }
      }
      
      if (closestBank != null) {
        final int bId = closestBank['bank_id'] as int;
        final bssiRows = LocalDatabase.instance.getTable('bssi_scores')
            .where((s) => s['bank_id'] == bId && s['blood_group'] == bg)
            .toList();
        final double bssi = bssiRows.isNotEmpty ? (bssiRows.first['score'] as num).toDouble() : 80.0;
        final int eta = (minDistance * 2).toInt() + 5;
        
        final mockNotif = {
          'log_id': 999,
          'alert_id': 999,
          'bank_name': closestBank['name'],
          'bank_address': closestBank['address'],
          'blood_group': bg,
          'bssi': bssi,
          'distance_km': double.parse(minDistance.toStringAsFixed(2)),
          'eta_minutes': eta,
          'phone': closestBank['contact_phone'] ?? '+919999000000',
          'bank_lat': closestBank['location_lat'],
          'bank_lng': closestBank['location_lng'],
          'user_start_lat': donorLat,
          'user_start_lng': donorLng,
        };
        setState(() => _isLoading = false);
        state.triggerMockNotification(mockNotif);
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      print("Error simulating mock push notification: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    
    // Auto popup alert receiver screen if we have an active notification
    if (state.pendingNotification != null) {
      return AlertReceivedScreen(notificationData: state.pendingNotification!);
    }

    final List<Widget> tabs = [
      _buildDashboardTab(state),
      _buildHistoryTab(state),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Donor Dashboard'),
        leading: const Icon(Icons.favorite, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => state.logout(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _resetPollingInterval();
          await _fetchDonorData();
          await _fetchDashboardData();
        },
        color: const Color(0xFF8B0000),
        child: _isLoading 
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF8B0000)))
            : tabs[_currentTab],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTab,
        selectedItemColor: const Color(0xFF8B0000),
        unselectedItemColor: Colors.grey,
        onTap: (idx) => setState(() => _currentTab = idx),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'History & Badges'),
        ],
      ),
    );
  }

  // --- TAB 1: DASHBOARD ---
  Widget _buildDashboardTab(AppState state) {
    final isEligible = _donorStats['eligibility_status'] == true;
    final lastDonation = _donorStats['last_donation_date'] as DateTime?;
    
    final cautionLevel = _dashboardData != null ? _dashboardData!['caution_level'] : 'NORMAL';
    final cautionMessage = _dashboardData != null 
        ? _dashboardData!['caution_message'] 
        : 'Blood levels for ${state.bloodGroup} are currently stable in your area. Keep monitoring.';
    final List banks = _dashboardData != null ? _dashboardData!['banks'] : [];

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // dynamic Urgency Caution Banner
            _buildCautionAlertWidget(cautionLevel, cautionMessage),
            
            // Status Card
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isEligible 
                      ? [const Color(0xFF30D158).withOpacity(0.12), Colors.white]
                      : [const Color(0xFFFF9F0A).withOpacity(0.12), Colors.white],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: isEligible ? const Color(0xFF30D158).withOpacity(0.25) : const Color(0xFFFF9F0A).withOpacity(0.25),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  )
                ],
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isEligible ? const Color(0xFF30D158).withOpacity(0.08) : const Color(0xFFFF9F0A).withOpacity(0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isEligible ? Icons.check_circle_outline : Icons.schedule,
                      color: isEligible ? const Color(0xFF30D158) : const Color(0xFFFF9F0A),
                      size: 44,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isEligible ? 'You are eligible to donate!' : 'You are currently resting',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isEligible 
                        ? 'Your blood group ${state.bloodGroup} is in demand. Ready to save a life?' 
                        : 'Eligible in ${_donorStats['eligible_in_days']} days (90 days interval required).',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Metrics Cards Row
            Row(
              children: [
                Expanded(
                  child: _buildMetricCard(
                    title: 'Total Donations',
                    value: '${_donorStats['total_donations']}',
                    subtitle: 'Units Contributed',
                    icon: Icons.water_drop,
                    iconColor: const Color(0xFFFF3B30),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildMetricCard(
                    title: 'Last Donated',
                    value: lastDonation != null ? DateFormat('dd MMM').format(lastDonation) : 'Never',
                    subtitle: lastDonation != null ? DateFormat('yyyy').format(lastDonation) : 'No records yet',
                    icon: Icons.calendar_today,
                    iconColor: Colors.blueAccent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Nearest Blood Banks in Need list
            _buildBanksInNeedList(banks, state.bloodGroup),
            const SizedBox(height: 24),

            // On-demand notification simulator card
            _buildSimulatorCard(state),
            const SizedBox(height: 24),

            // Profile info card
            Builder(
              builder: (context) {
                final dobStr = _dashboardData != null ? _dashboardData!['dob'] : null;
                final docName = _dashboardData != null ? _dashboardData!['id_document_name'] : null;
                
                String ageDisplay = 'Loading...';
                String dobDisplay = 'Loading...';
                if (dobStr != null) {
                  try {
                    final dob = DateTime.parse(dobStr);
                    dobDisplay = DateFormat('dd MMMM yyyy').format(dob);
                    
                    DateTime today = DateTime.now();
                    int age = today.year - dob.year;
                    if (today.month < dob.month || (today.month == dob.month && today.day < dob.day)) {
                      age--;
                    }
                    ageDisplay = '$age Years';
                  } catch (e) {
                    print("Error parsing dob: $e");
                  }
                }

                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Donor Profile', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                        const SizedBox(height: 16),
                        _buildProfileRow(Icons.person_outline, 'Name', state.name),
                        const Divider(height: 24, color: Color(0xFFE2E8F0)),
                        _buildProfileRow(Icons.bloodtype_outlined, 'Blood Group', state.bloodGroup),
                        const Divider(height: 24, color: Color(0xFFE2E8F0)),
                        _buildProfileRow(Icons.location_city_outlined, 'Registered Region', state.city),
                        const Divider(height: 24, color: Color(0xFFE2E8F0)),
                        _buildProfileRow(Icons.phone_iphone, 'Phone', state.phone),
                        const Divider(height: 24, color: Color(0xFFE2E8F0)),
                        _buildProfileRow(Icons.calendar_month_outlined, 'Date of Birth', dobDisplay),
                        const Divider(height: 24, color: Color(0xFFE2E8F0)),
                        _buildProfileRow(Icons.cake_outlined, 'Calculated Age', ageDisplay),
                        const Divider(height: 24, color: Color(0xFFE2E8F0)),
                        _buildProfileRow(
                          Icons.verified_user_outlined, 
                          'Verification Document', 
                          (docName != null && docName.length > 4)
                              ? '***${docName.substring(docName.length - 4)}'
                              : (docName ?? 'Aadhaar / License Uploaded'),
                        ),
                      ],
                    ),
                  ),
                );
              }
            ),
            const SizedBox(height: 24),
            
            // Helpful Tip
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFE2E8F0).withOpacity(0.4),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.blue, size: 22),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Keep push notifications active! Critical BSSI shortage alerts rely on proximity matching to contact you.',
                      style: TextStyle(fontSize: 12, color: const Color(0xFF64748B), height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCautionAlertWidget(String level, String message) {
    Color cardColor = const Color(0xFF30D158);
    IconData icon = Icons.check_circle_outline;
    if (level == 'CRITICAL') {
      cardColor = const Color(0xFF8B0000);
      icon = Icons.warning_amber_rounded;
    } else if (level == 'WARNING') {
      cardColor = const Color(0xFFFF9F0A);
      icon = Icons.warning_amber_rounded;
    }
    
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cardColor.withOpacity(0.35), width: 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cardColor.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: cardColor, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${level == 'NORMAL' ? 'STABLE' : level} REGIONAL CAUTION',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: cardColor,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF2C2C2C),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildBanksInNeedList(List banks, String donorBloodGroup) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'NEAREST BLOOD BANKS IN NEED',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.0),
        ),
        const SizedBox(height: 12),
        if (banks.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20.0),
              child: Center(
                child: Text('No local blood banks found.', style: TextStyle(color: Colors.grey)),
              ),
            ),
          )
        else
          ...banks.map((bank) {
            final double bssi = (bank['bssi'] as num).toDouble();
            final double dist = (bank['distance_km'] as num).toDouble();
            final double units = (bank['units_available'] as num).toDouble();
            
            Color statusColor = const Color(0xFF30D158);
            if (bssi > 75) {
              statusColor = const Color(0xFFFF3B30);
            } else if (bssi > 55) {
              statusColor = const Color(0xFFFF9F0A);
            }
            
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: statusColor.withOpacity(0.2)),
                          ),
                          child: Icon(Icons.local_hospital, color: statusColor, size: 22),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                bank['bank_name'] ?? 'Blood Bank',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF2C2C2C)),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                bank['address'] ?? 'No address available',
                                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const Icon(Icons.location_on, size: 12, color: Color(0xFF64748B)),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${dist.toStringAsFixed(1)} km away (${bank['eta_minutes']} mins)',
                                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: statusColor.withOpacity(0.3)),
                          ),
                          child: Text(
                            'BSSI: ${bssi.toStringAsFixed(0)}',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: statusColor),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 24, color: Color(0xFFE2E8F0)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Text('Stock: ', style: TextStyle(fontSize: 12, color: Colors.grey)),
                            Text(
                              '${units.toStringAsFixed(1)} Units',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: units < 15.0 ? const Color(0xFF8B0000) : const Color(0xFF2C2C2C),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE2E8F0),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                donorBloodGroup,
                                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF64748B)),
                              ),
                            ),
                          ],
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _triggerMockMobilizationForBank(bank),
                          icon: const Icon(Icons.emergency_share, size: 14),
                          label: const Text('Rush to Donate', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: statusColor == const Color(0xFFFF3B30) ? const Color(0xFF8B0000) : statusColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        )
                      ],
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
      ],
    );
  }

  Widget _buildSimulatorCard(AppState state) {
    return Card(
      color: const Color(0xFFFFF5F5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: const Color(0xFF8B0000).withOpacity(0.25), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.construction, color: Color(0xFF8B0000), size: 18),
                SizedBox(width: 8),
                Text(
                  'MOBILIZATION SIMULATOR',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF8B0000),
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Simulate receiving a mock regional push notification alert for a shortage of your blood group (${state.bloodGroup}) in ${state.city}.',
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), height: 1.4),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _simulateMockPushNotification(state),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B0000),
                foregroundColor: Colors.white,
                elevation: 1,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.notifications_active, size: 18),
                  SizedBox(width: 8),
                  Text('Trigger Shortage Notification', style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                Icon(icon, color: iconColor, size: 20),
              ],
            ),
            const SizedBox(height: 16),
            Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2C))),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF8B0000), size: 20),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF2C2C2C))),
          ],
        )
      ],
    );
  }

  // --- TAB 2: HISTORY & BADGES ---
  Widget _buildHistoryTab(AppState state) {
    final count = _donorStats['total_donations'] as int;
    final List history = _donorStats['donations_history'];

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Badges Grid
          const Text('Your Badges & Achievements', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildBadgeItem(
                name: 'First Blood',
                description: 'First donation',
                unlocked: count >= 1,
                icon: Icons.verified_user,
                color: Colors.amber,
              ),
              _buildBadgeItem(
                name: 'Life Saver V',
                description: '5 donations',
                unlocked: count >= 5,
                icon: Icons.military_tech,
                color: Colors.redAccent,
              ),
              _buildBadgeItem(
                name: 'Champion X',
                description: '10 donations',
                unlocked: count >= 10,
                icon: Icons.emoji_events,
                color: Colors.purple,
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(color: Color(0xFFE2E8F0)),
          const SizedBox(height: 12),
          
          // History Title
          const Text('Donation Records Log', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
          const SizedBox(height: 12),
          
          Expanded(
            child: history.isEmpty
                ? const Center(
                    child: Text(
                      'No donation records logged yet.',
                      style: TextStyle(color: Color(0xFF64748B)),
                    ),
                  )
                : ListView.builder(
                    itemCount: history.length,
                    itemBuilder: (context, index) {
                      final item = history[index];
                      final date = DateTime.parse(item['donated_at']);
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8B0000).withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.water_drop, color: Color(0xFF8B0000)),
                          ),
                          title: Text(item['bank_name'] ?? 'Blood Bank', style: const TextStyle(color: Color(0xFF2C2C2C), fontWeight: FontWeight.bold)),
                          subtitle: Text(DateFormat('dd MMMM yyyy').format(date), style: const TextStyle(color: Color(0xFF64748B))),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '${item['units']} Unit',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF2C2C2C)),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item['blood_group'] ?? '',
                                style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildBadgeItem({
    required String name,
    required String description,
    required bool unlocked,
    required IconData icon,
    required Color color,
  }) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: unlocked ? color.withOpacity(0.15) : const Color(0xFFE2E8F0).withOpacity(0.4),
            shape: BoxShape.circle,
            border: Border.all(
              color: unlocked ? color : const Color(0xFFE2E8F0),
              width: 1.5,
            ),
          ),
          child: Icon(
            icon,
            color: unlocked ? color : Colors.grey.withOpacity(0.5),
            size: 32,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          name,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13,
            color: unlocked ? const Color(0xFF2C2C2C) : const Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          description,
          style: TextStyle(
            fontSize: 10,
            color: unlocked ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
          ),
        ),
      ],
    );
  }
}

// --- ALERT RECEIVED OVERLAY SCREEN ---
class AlertReceivedScreen extends StatefulWidget {
  final Map<String, dynamic> notificationData;
  const AlertReceivedScreen({super.key, required this.notificationData});

  @override
  State<AlertReceivedScreen> createState() => _AlertReceivedScreenState();
}

class _AlertReceivedScreenState extends State<AlertReceivedScreen> {
  bool _isActioning = false;
  bool _navigationLaunched = false;
  double _userLat = 13.0827; // default Chennai
  double _userLng = 80.2707;

  @override
  void initState() {
    super.initState();
    _loadUserLocation();
  }

  Future<void> _loadUserLocation() async {
    if (widget.notificationData['log_id'] == 999) {
      setState(() {
        _userLat = 13.0494; // Vadapalani, Chennai
        _userLng = 80.2104;
      });
      return;
    }
    final coords = await GeolocationHelper.getCurrentLocation();
    if (coords != null) {
      setState(() {
        _userLat = coords.latitude;
        _userLng = coords.longitude;
      });
    }
  }

  Future<void> _respondToAlert(String responseType) async {
    setState(() => _isActioning = true);
    final state = Provider.of<AppState>(context, listen: false);
    
    try {
      await Future.delayed(const Duration(milliseconds: 600));
      if (responseType == 'accepted') {
        setState(() {
          _navigationLaunched = true;
          _isActioning = false;
        });
      } else {
        state.clearNotification();
      }
    } catch (e) {
      if (responseType == 'accepted') {
        setState(() {
          _navigationLaunched = true;
          _isActioning = false;
        });
      } else {
        state.clearNotification();
      }
      print("Error responding to alert: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.notificationData;
    final bssi = data['bssi'] ?? 65.0;
    
    // Choose urgency color
    Color urgencyColor = const Color(0xFFFF9F0A); // warning
    if (bssi > 75) urgencyColor = const Color(0xFF8B0000); // emergency

    if (_navigationLaunched) {
      final viewType = 'geoapify-map-${widget.notificationData['log_id']}-$_userLat-$_userLng';
      // ignore: undefined_prefixed_name
      ui_web.platformViewRegistry.registerViewFactory(
        viewType,
        (int viewId) {
          final bankLat = widget.notificationData['bank_lat'] ?? 13.0067;
          final bankLng = widget.notificationData['bank_lng'] ?? 80.2206;
          final iframe = html.IFrameElement()
            ..src = 'map.html?lat=$_userLat&lng=$_userLng&bankLat=$bankLat&bankLng=$bankLng&apiKey=1d6b9e8325e840f48096e1063e04ffe6'
            ..style.border = 'none'
            ..style.width = '100%'
            ..style.height = '100%'
            ..setAttribute('allow', 'geolocation');
          return iframe;
        },
      );

      return Scaffold(
        appBar: AppBar(
          title: const Text('Navigation Route to Bank'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              final state = Provider.of<AppState>(context, listen: false);
              state.clearNotification();
            },
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  // Live interactive road-network map via Geoapify
                  Positioned.fill(
                    child: HtmlElementView(
                      viewType: viewType,
                    ),
                  ),
                  Positioned(
                    top: 20,
                    left: 20,
                    right: 20,
                    child: Card(
                      color: Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          children: [
                            const Icon(Icons.navigation, color: Colors.blue, size: 28),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    data['bank_name'] ?? 'Target Blood Bank',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF2C2C2C)),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    data['bank_address'] ?? 'No address available',
                                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Distance: ${data['distance_km'] ?? "0.0"} km | ETA: ${data['eta_minutes'] ?? "0"} mins',
                                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                  ),
                                ],
                              ),
                            )
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'ETA: ${data['eta_minutes'] ?? 8} Mins',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Distance: ${data['distance_km'] ?? 3.4} km',
                        style: const TextStyle(color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                  ElevatedButton(
                    onPressed: () {
                      final state = Provider.of<AppState>(context, listen: false);
                      state.clearNotification();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8B0000),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('End Navigation', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F5),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Heart pulse ring simulation
              Center(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: urgencyColor.withOpacity(0.1),
                    shape: BoxShape.circle,
                    border: Border.all(color: urgencyColor.withOpacity(0.3), width: 2),
                  ),
                  child: Icon(Icons.emergency_share, size: 64, color: urgencyColor),
                ),
              ),
              const SizedBox(height: 32),
              
              Text(
                'CRITICAL BLOOD SHORTAGE ALERT',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: urgencyColor,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 16),
              
              Text(
                '${data['blood_group'] ?? 'O+'} Needed Urgently',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2C2C2C),
                ),
              ),
              const SizedBox(height: 12),
              
              Text(
                'The regional shortage index (BSSI) for your blood group has reached a warning level of $bssi. Your donation is requested immediately.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF64748B),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),
              
              // Details Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      _buildAlertDetailRow('Blood Bank', data['bank_name'] ?? 'Blood Bank'),
                      const Divider(height: 24, color: Color(0xFFE2E8F0)),
                      _buildAlertDetailRow('Address', data['bank_address'] ?? 'No address available'),
                      const Divider(height: 24, color: Color(0xFFE2E8F0)),
                      _buildAlertDetailRow('Distance', '${data['distance_km'] ?? 3.4} km'),
                      const Divider(height: 24, color: Color(0xFFE2E8F0)),
                      _buildAlertDetailRow('ETA to Center', '${data['eta_minutes'] ?? 8} minutes'),
                      const Divider(height: 24, color: Color(0xFFE2E8F0)),
                      _buildAlertDetailRow('BSSI Urgency', '$bssi / 100', valueColor: urgencyColor),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 40),
              
              // Actions
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isActioning ? null : () => _respondToAlert('declined'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        side: const BorderSide(color: Color(0xFFE2E8F0)),
                        foregroundColor: const Color(0xFF64748B),
                      ),
                      child: const Text('Cannot Donate', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isActioning ? null : () => _respondToAlert('accepted'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B0000),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _isActioning
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text('I Will Donate', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAlertDetailRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFF64748B))),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: valueColor ?? const Color(0xFF2C2C2C),
          ),
        ),
      ],
    );
  }
}

// --- VECTOR MAP SIMULATION PAINTER ---
class MapNavigationPainter extends CustomPainter {
  final String bankName;
  final double distance;
  MapNavigationPainter({required this.bankName, required this.distance});

  @override
  void paint(Canvas canvas, Size size) {
    // Background Dark Grid
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.03)
      ..strokeWidth = 1.0;
      
    const double step = 30.0;
    for (double i = 0; i < size.width; i += step) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), gridPaint);
    }
    for (double i = 0; i < size.height; i += step) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), gridPaint);
    }

    // Coordinates definition
    final startPt = Offset(size.width * 0.25, size.height * 0.7);
    final controlPt1 = Offset(size.width * 0.4, size.height * 0.5);
    final controlPt2 = Offset(size.width * 0.3, size.height * 0.35);
    final endPt = Offset(size.width * 0.65, size.height * 0.25);

    // Draw Route Path
    final routePath = Path()
      ..moveTo(startPt.dx, startPt.dy)
      ..cubicTo(controlPt1.dx, controlPt1.dy, controlPt2.dx, controlPt2.dy, endPt.dx, endPt.dy);

    final pathPaint = Paint()
      ..color = Colors.blue.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8.0
      ..strokeCap = StrokeCap.round;

    final dashPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(routePath, pathPaint);
    canvas.drawPath(routePath, dashPaint);

    // Draw My Location Point (Blue pulse)
    final bluePulse = Paint()..color = Colors.blue.withOpacity(0.25);
    final blueDot = Paint()..color = Colors.blue;
    canvas.drawCircle(startPt, 22.0, bluePulse);
    canvas.drawCircle(startPt, 8.0, blueDot);

    // Draw Blood Bank Target (Red locator tag)
    final redPulse = Paint()..color = const Color(0xFFFF3B30).withOpacity(0.25);
    final redDot = Paint()..color = const Color(0xFFFF3B30);
    canvas.drawCircle(endPt, 28.0, redPulse);
    canvas.drawCircle(endPt, 12.0, redDot);

    // Draw Marker Pins Text
    const textStyle = TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold);
    final textSpan = TextSpan(text: bankName, style: textStyle);
    final textPainter = TextPainter(text: textSpan, textDirection: ui.TextDirection.ltr);
    textPainter.layout(minWidth: 0, maxWidth: 120);
    textPainter.paint(canvas, Offset(endPt.dx - 40, endPt.dy - 45));

    final myTextSpan = const TextSpan(text: 'My Location', style: TextStyle(color: Colors.blue, fontSize: 11, fontWeight: FontWeight.bold));
    final myTextPainter = TextPainter(text: myTextSpan, textDirection: ui.TextDirection.ltr);
    myTextPainter.layout();
    myTextPainter.paint(canvas, Offset(startPt.dx - 30, startPt.dy + 15));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _GPSCoords {
  final double latitude;
  final double longitude;
  _GPSCoords(this.latitude, this.longitude);
}
