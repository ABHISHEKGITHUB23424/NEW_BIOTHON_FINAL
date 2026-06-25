import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

class LocalDatabase {
  static final LocalDatabase instance = LocalDatabase._init();
  LocalDatabase._init();

  // In-memory cache of tables
  Map<String, List<Map<String, dynamic>>> _tables = {};
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    final prefs = await SharedPreferences.getInstance();

    final tableNames = [
      'regions',
      'blood_banks',
      'hospitals',
      'donors',
      'donation_records',
      'transfusion_records',
      'blood_inventory',
      'bssi_scores',
      'shortage_alerts',
      'donor_alert_log',
      'redistributions',
      'emergency_events'
    ];

    for (var name in tableNames) {
      final jsonStr = prefs.getString('db_$name');
      if (jsonStr != null) {
        final decoded = jsonDecode(jsonStr) as List;
        _tables[name] = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      } else {
        _tables[name] = [];
      }
    }

    _isInitialized = true;

    // Seed data if empty
    if (_tables['regions']!.isEmpty) {
      await seedDatabase();
    }
  }

  Future<void> _saveTable(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('db_$name', jsonEncode(_tables[name]));
  }

  List<Map<String, dynamic>> getTable(String name) {
    return _tables[name] ?? [];
  }

  Future<Map<String, dynamic>> insert(String tableName, Map<String, dynamic> row, String idField) async {
    await init();
    final table = _tables[tableName] ?? [];
    
    // Auto-increment primary key
    int maxId = 0;
    for (var r in table) {
      final idVal = r[idField] as int? ?? 0;
      if (idVal > maxId) maxId = idVal;
    }
    final newId = maxId + 1;
    final newRow = Map<String, dynamic>.from(row);
    newRow[idField] = newId;
    
    table.add(newRow);
    _tables[tableName] = table;
    await _saveTable(tableName);
    return newRow;
  }

  Future<void> update(String tableName, String idField, int id, Map<String, dynamic> updatedFields) async {
    await init();
    final table = _tables[tableName] ?? [];
    for (var i = 0; i < table.length; i++) {
      if (table[i][idField] == id) {
        table[i].addAll(updatedFields);
        break;
      }
    }
    await _saveTable(tableName);
  }

  Future<void> delete(String tableName, String idField, int id) async {
    await init();
    final table = _tables[tableName] ?? [];
    table.removeWhere((r) => r[idField] == id);
    await _saveTable(tableName);
  }

  // Clear database helper
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('db_')).toList();
    for (var k in keys) {
      await prefs.remove(k);
    }
    _tables.clear();
    _isInitialized = false;
    await init();
  }

  // Seeding Logic
  Future<void> seedDatabase() async {
    print('Seeding local database...');
    
    // 1. Seed Regions
    final regions = [
      {'region_id': 1, 'name': 'Delhi NCR', 'state': 'Delhi', 'district': 'Delhi', 'accident_risk_level': 3},
      {'region_id': 2, 'name': 'Mumbai MMR', 'state': 'Maharashtra', 'district': 'Mumbai', 'accident_risk_level': 4},
      {'region_id': 3, 'name': 'Bengaluru Urban', 'state': 'Karnataka', 'district': 'Bengaluru', 'accident_risk_level': 2},
      {'region_id': 4, 'name': 'Chennai', 'state': 'Tamil Nadu', 'district': 'Chennai', 'accident_risk_level': 3},
    ];
    _tables['regions'] = regions;
    await _saveTable('regions');

    // 2. Seed Blood Banks
    final banks = [
      {'bank_id': 1, 'name': 'Delhi NCR Main Bank', 'location_lat': 28.6139, 'location_lng': 77.2090, 'region_id': 1, 'contact_phone': '+919876543210', 'address': 'Central Delhi, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 2, 'name': 'Noida Metro Bank', 'location_lat': 28.5355, 'location_lng': 77.3910, 'region_id': 1, 'contact_phone': '+919876543211', 'address': 'Sector 18, Noida, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 3, 'name': 'Gurgaon City Bank', 'location_lat': 28.4595, 'location_lng': 77.0266, 'region_id': 1, 'contact_phone': '+919876543212', 'address': 'DLF Phase 3, Gurgaon, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 4, 'name': 'Mumbai Main Bank', 'location_lat': 19.0760, 'location_lng': 72.8777, 'region_id': 2, 'contact_phone': '+919876543213', 'address': 'Colaba, Mumbai, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 5, 'name': 'Thane Regional Bank', 'location_lat': 19.2183, 'location_lng': 72.9781, 'region_id': 2, 'contact_phone': '+919876543214', 'address': 'Wagle Estate, Thane, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 6, 'name': 'Navi Mumbai Bank', 'location_lat': 19.0330, 'location_lng': 73.0297, 'region_id': 2, 'contact_phone': '+919876543215', 'address': 'Vashi, Navi Mumbai, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 7, 'name': 'Bengaluru Urban Main', 'location_lat': 12.9716, 'location_lng': 77.5946, 'region_id': 3, 'contact_phone': '+919876543216', 'address': 'MG Road, Bengaluru, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 8, 'name': 'Koramangala Blood Depot', 'location_lat': 12.9279, 'location_lng': 77.6271, 'region_id': 3, 'contact_phone': '+919876543217', 'address': 'Koramangala 4th Block, Bengaluru, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 9, 'name': 'Hebbal Emergency Bank', 'location_lat': 13.0285, 'location_lng': 77.5896, 'region_id': 3, 'contact_phone': '+919876543218', 'address': 'Hebbal, Bengaluru, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 10, 'name': 'Chennai Central Bank', 'location_lat': 13.0827, 'location_lng': 80.2707, 'region_id': 4, 'contact_phone': '+919876543219', 'address': 'Egmore, Chennai, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 11, 'name': 'Guindy Metro Depot', 'location_lat': 13.0067, 'location_lng': 80.2206, 'region_id': 4, 'contact_phone': '+919876543220', 'address': 'Guindy, Chennai, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
      {'bank_id': 12, 'name': 'T. Nagar Emergency Bank', 'location_lat': 13.0405, 'location_lng': 80.2337, 'region_id': 4, 'contact_phone': '+919876543221', 'address': 'T. Nagar, Chennai, India', 'password_hash': 'e10adc3949ba59abbe56e057f20f883e', 'is_approved': true},
    ];
    _tables['blood_banks'] = banks;
    await _saveTable('blood_banks');

    // 3. Seed Hospitals
    final hospitals = [
      {'hospital_id': 1, 'name': 'Apollo Indraprastha Hospital', 'location_lat': 28.5350, 'location_lng': 77.2910, 'region_id': 1, 'address': 'Sarita Vihar, Delhi', 'avg_daily_consumption': {'O+': 4.5, 'O-': 1.0, 'A+': 3.2, 'A-': 0.8, 'B+': 3.5, 'B-': 0.6, 'AB+': 1.5, 'AB-': 0.4}},
      {'hospital_id': 2, 'name': 'Max Super Speciality Hospital', 'location_lat': 28.5284, 'location_lng': 77.2197, 'region_id': 1, 'address': 'Saket, Delhi', 'avg_daily_consumption': {'O+': 3.8, 'O-': 0.8, 'A+': 2.8, 'A-': 0.6, 'B+': 3.0, 'B-': 0.5, 'AB+': 1.2, 'AB-': 0.3}},
      {'hospital_id': 3, 'name': 'KEM Hospital Mumbai', 'location_lat': 19.0028, 'location_lng': 72.8422, 'region_id': 2, 'address': 'Parel, Mumbai', 'avg_daily_consumption': {'O+': 6.0, 'O-': 1.5, 'A+': 4.5, 'A-': 1.2, 'B+': 5.0, 'B-': 1.0, 'AB+': 2.0, 'AB-': 0.5}},
      {'hospital_id': 4, 'name': 'Lilavati Hospital & Research Centre', 'location_lat': 19.0514, 'location_lng': 72.8279, 'region_id': 2, 'address': 'Bandra West, Mumbai', 'avg_daily_consumption': {'O+': 4.2, 'O-': 0.9, 'A+': 3.0, 'A-': 0.7, 'B+': 3.4, 'B-': 0.6, 'AB+': 1.4, 'AB-': 0.4}},
      {'hospital_id': 5, 'name': 'Fortis Hospital Bengaluru', 'location_lat': 12.8943, 'location_lng': 77.5986, 'region_id': 3, 'address': 'Bannerghatta Road, Bengaluru', 'avg_daily_consumption': {'O+': 3.5, 'O-': 0.7, 'A+': 2.5, 'A-': 0.5, 'B+': 2.8, 'B-': 0.4, 'AB+': 1.0, 'AB-': 0.2}},
      {'hospital_id': 6, 'name': 'Manipal Hospital Hal Road', 'location_lat': 12.9592, 'location_lng': 77.6444, 'region_id': 3, 'address': 'HAL Airport Road, Bengaluru', 'avg_daily_consumption': {'O+': 5.2, 'O-': 1.2, 'A+': 3.8, 'A-': 0.9, 'B+': 4.2, 'B-': 0.8, 'AB+': 1.8, 'AB-': 0.4}},
      {'hospital_id': 7, 'name': 'Fortis Malar Hospital Chennai', 'location_lat': 13.0063, 'location_lng': 80.2573, 'region_id': 4, 'address': 'Adyar, Chennai', 'avg_daily_consumption': {'O+': 3.2, 'O-': 0.6, 'A+': 2.2, 'A-': 0.4, 'B+': 2.6, 'B-': 0.4, 'AB+': 1.0, 'AB-': 0.2}},
      {'hospital_id': 8, 'name': 'Government General Hospital Chennai', 'location_lat': 13.0822, 'location_lng': 80.2755, 'region_id': 4, 'address': 'Park Town, Chennai', 'avg_daily_consumption': {'O+': 7.5, 'O-': 2.0, 'A+': 5.5, 'A-': 1.5, 'B+': 6.0, 'B-': 1.2, 'AB+': 2.5, 'AB-': 0.6}},
    ];
    _tables['hospitals'] = hospitals;
    await _saveTable('hospitals');

    // 4. Seed Blood Inventory for all 12 banks across all 8 blood groups
    final bloodGroups = ['O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-'];
    final List<Map<String, dynamic>> inventory = [];
    final random = Random(42);
    int invId = 1;
    for (int bId = 1; bId <= 12; bId++) {
      for (var bg in bloodGroups) {
        // Delhi NCR main bank is seeded with normal stock, while Noida is seeded with critical shortages to trigger alerts
        double units = 35.0 + random.nextDouble() * 20.0;
        if (bId == 2 && (bg == 'O+' || bg == 'O-' || bg == 'A+')) {
          units = 5.0 + random.nextDouble() * 5.0; // Shortage units (BSSI will be high)
        } else if (bId == 8 && (bg == 'B+' || bg == 'AB+')) {
          units = 8.0 + random.nextDouble() * 4.0;
        }
        inventory.add({
          'inventory_id': invId++,
          'bank_id': bId,
          'blood_group': bg,
          'units_available': units,
          'units_expiring_3days': (units > 15.0) ? (random.nextDouble() * 4.0) : 0.0,
          'last_updated': DateTime.now().toIso8601String(),
        });
      }
    }
    _tables['blood_inventory'] = inventory;
    await _saveTable('blood_inventory');

    // 5. Seed Donors (UCI representation)
    final donors = [
      {'donor_id': 1, 'firebase_uid': 'mock_uid_donor_1', 'name': 'Aditya Sharma', 'phone': '+919999999901', 'blood_group': 'O+', 'dob': '1990-05-15', 'location_lat': 28.6150, 'location_lng': 77.2110, 'is_eligible': true, 'response_count': 4, 'alert_count': 5, 'response_rate': 0.8, 'consent_given': true},
      {'donor_id': 2, 'firebase_uid': 'mock_uid_donor_2', 'name': 'Rajesh Kumar', 'phone': '+919999999902', 'blood_group': 'O-', 'dob': '1985-08-22', 'location_lat': 28.6250, 'location_lng': 77.2000, 'is_eligible': true, 'response_count': 1, 'alert_count': 3, 'response_rate': 0.33, 'consent_given': true},
      {'donor_id': 3, 'firebase_uid': 'mock_uid_donor_3', 'name': 'Priya Patel', 'phone': '+919999999903', 'blood_group': 'A+', 'dob': '1993-11-02', 'location_lat': 28.5400, 'location_lng': 77.3800, 'is_eligible': true, 'response_count': 0, 'alert_count': 2, 'response_rate': 0.0, 'consent_given': true},
      {'donor_id': 4, 'firebase_uid': 'mock_uid_donor_4', 'name': 'Vikram Singh', 'phone': '+919999999904', 'blood_group': 'B+', 'dob': '1988-02-14', 'location_lat': 19.0800, 'location_lng': 72.8800, 'is_eligible': true, 'response_count': 3, 'alert_count': 3, 'response_rate': 1.0, 'consent_given': true},
      {'donor_id': 5, 'firebase_uid': 'mock_uid_donor_5', 'name': 'Ananya Rao', 'phone': '+919999999905', 'blood_group': 'AB+', 'dob': '1995-07-30', 'location_lat': 12.9800, 'location_lng': 77.6000, 'is_eligible': true, 'response_count': 2, 'alert_count': 4, 'response_rate': 0.5, 'consent_given': true},
      {'donor_id': 6, 'firebase_uid': 'mock_uid_donor_6', 'name': 'Siddharth Nair', 'phone': '+919999999906', 'blood_group': 'O+', 'dob': '1992-04-18', 'location_lat': 13.0900, 'location_lng': 80.2800, 'is_eligible': true, 'response_count': 5, 'alert_count': 6, 'response_rate': 0.83, 'consent_given': true},
    ];
    _tables['donors'] = donors;
    await _saveTable('donors');

    // 6. Seed Donation Records (History for BSSI/Models)
    final List<Map<String, dynamic>> donationRecords = [];
    int recId = 1;
    final today = DateTime.now();
    for (int i = 0; i < 150; i++) {
      final daysAgo = random.nextInt(180) + 1;
      final donatedDate = today.subtract(Duration(days: daysAgo));
      final bId = random.nextInt(12) + 1;
      final bg = bloodGroups[random.nextInt(8)];
      donationRecords.add({
        'record_id': recId++,
        'donor_id': random.nextInt(6) + 1,
        'bank_id': bId,
        'blood_group': bg,
        'units': 1.0,
        'donated_at': donatedDate.toIso8601String().split('T')[0],
        'is_festival_day': random.nextDouble() < 0.1,
        'accident_count_that_day': random.nextInt(3),
        'season': (donatedDate.month >= 3 && donatedDate.month <= 6) ? 'Summer' : (donatedDate.month >= 7 && donatedDate.month <= 10) ? 'Monsoon' : 'Winter',
      });
    }
    _tables['donation_records'] = donationRecords;
    await _saveTable('donation_records');

    // 7. Seed Transfusion Records (Outflows)
    final List<Map<String, dynamic>> transfusionRecords = [];
    int transId = 1;
    for (int i = 0; i < 120; i++) {
      final daysAgo = random.nextInt(180) + 1;
      final transfusedDate = today.subtract(Duration(days: daysAgo));
      final hospId = random.nextInt(8) + 1;
      final bg = bloodGroups[random.nextInt(8)];
      transfusionRecords.add({
        'record_id': transId++,
        'hospital_id': hospId,
        'blood_group': bg,
        'units': 1.0 + random.nextInt(3).toDouble(),
        'transfused_at': transfusedDate.toIso8601String().split('T')[0],
        'emergency_flag': random.nextDouble() < 0.15,
      });
    }
    _tables['transfusion_records'] = transfusionRecords;
    await _saveTable('transfusion_records');

    // 8. Seed Emergency Events
    final emergencyEvents = [
      {'event_id': 1, 'region_id': 1, 'event_type': 'Seasonal Dengue Outbreak', 'severity': 4, 'event_date': today.subtract(const Duration(days: 2)).toIso8601String().split('T')[0], 'estimated_blood_impact_units': 45.0},
      {'event_id': 2, 'region_id': 2, 'event_type': 'Heavy Monsoon Floods', 'severity': 3, 'event_date': today.subtract(const Duration(days: 10)).toIso8601String().split('T')[0], 'estimated_blood_impact_units': 30.0},
    ];
    _tables['emergency_events'] = emergencyEvents;
    await _saveTable('emergency_events');

    // 9. Initial BSSI Calculations
    // Seed basic BSSI scores for Delhi NCR Main Bank (Bank 1) and Noida (Bank 2)
    final List<Map<String, dynamic>> bssiList = [];
    int scoreId = 1;
    for (int bId = 1; bId <= 12; bId++) {
      for (var bg in bloodGroups) {
        double score = 15.0 + random.nextDouble() * 20.0;
        if (bId == 2 && (bg == 'O+' || bg == 'O-' || bg == 'A+')) {
          score = 80.0 + random.nextDouble() * 12.0; // High BSSI
        } else if (bId == 8 && (bg == 'B+' || bg == 'AB+')) {
          score = 76.0 + random.nextDouble() * 8.0;
        }
        bssiList.add({
          'score_id': scoreId++,
          'bank_id': bId,
          'blood_group': bg,
          'score': score,
          'inventory_gap_score': 0.1,
          'donation_trend_score': 0.05,
          'accident_signal_score': 0.0,
          'rare_group_flag': (bg == 'AB-' || bg == 'O-') ? 0.15 : 0.0,
          'expiry_pressure_score': 0.0,
          'computed_at': DateTime.now().toIso8601String(),
        });
      }
    }
    _tables['bssi_scores'] = bssiList;
    await _saveTable('bssi_scores');

    // 10. Seed critical alerts list
    final alerts = [
      {
        'alert_id': 1,
        'bank_id': 2,
        'blood_group': 'O+',
        'bssi_at_trigger': 85.5,
        'donors_notified': 300,
        'donors_responded': 8,
        'response_rate': 0.026,
        'triggered_at': today.subtract(const Duration(hours: 4)).toIso8601String(),
      },
      {
        'alert_id': 2,
        'bank_id': 2,
        'blood_group': 'O-',
        'bssi_at_trigger': 78.2,
        'donors_notified': 120,
        'donors_responded': 3,
        'response_rate': 0.025,
        'triggered_at': today.subtract(const Duration(hours: 12)).toIso8601String(),
      }
    ];
    _tables['shortage_alerts'] = alerts;
    await _saveTable('shortage_alerts');

    // 11. Seed Donor Alert Logs
    final logs = [
      {'log_id': 1, 'alert_id': 1, 'donor_id': 1, 'notified_at': today.subtract(const Duration(hours: 4)).toIso8601String(), 'response': 'accepted', 'responded_at': today.subtract(const Duration(hours: 3)).toIso8601String()},
      {'log_id': 2, 'alert_id': 1, 'donor_id': 2, 'notified_at': today.subtract(const Duration(hours: 4)).toIso8601String(), 'response': 'no_response', 'responded_at': null},
    ];
    _tables['donor_alert_log'] = logs;
    await _saveTable('donor_alert_log');

    print('Seeding completed successfully!');
  }
}
