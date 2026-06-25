import 'dart:math';
import '../data/local_db.dart';

class BssiService {
  static final BssiService instance = BssiService._init();
  BssiService._init();

  final LocalDatabase _db = LocalDatabase.instance;

  // Calculates BSSI Composite score for a blood group at a specific bank
  Future<Map<String, dynamic>> computeBssi(int bankId, String bloodGroup) async {
    await _db.init();

    // 1. Inventory Gap Score (Weight: 0.35)
    // predicted_7day_demand vs units_available
    final forecasts = _db.getTable('forecast_cache')
        .where((f) => f['bank_id'] == bankId && f['blood_group'] == bloodGroup)
        .toList();
    
    double predicted7DayDemand = 0.0;
    for (var f in forecasts) {
      predicted7DayDemand += (f['yhat'] as num).toDouble();
    }

    if (predicted7DayDemand <= 0) {
      predicted7DayDemand = 14.0; // Safe floor fallback
    }

    final inventoryRows = _db.getTable('blood_inventory')
        .where((i) => i['bank_id'] == bankId && i['blood_group'] == bloodGroup)
        .toList();
    
    double unitsAvailable = 0.0;
    double unitsExpiring3Days = 0.0;
    if (inventoryRows.isNotEmpty) {
      unitsAvailable = (inventoryRows.first['units_available'] as num).toDouble();
      unitsExpiring3Days = (inventoryRows.first['units_expiring_3days'] as num).toDouble();
    }

    double inventoryGapScore = (predicted7DayDemand - unitsAvailable) / predicted7DayDemand;

    // 2. Donation Trend Score (Weight: 0.25)
    // Linear regression slope on last 7 days of daily donation counts
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    Map<String, double> donationsMap = {};
    for (int i = 1; i <= 7; i++) {
      final dateStr = today.subtract(Duration(days: i)).toIso8601String().split('T')[0];
      donationsMap[dateStr] = 0.0;
    }

    final donations = _db.getTable('donation_records')
        .where((d) => d['bank_id'] == bankId && d['blood_group'] == bloodGroup)
        .toList();

    for (var d in donations) {
      final donatedAt = d['donated_at'] as String;
      if (donationsMap.containsKey(donatedAt)) {
        donationsMap[donatedAt] = (donationsMap[donatedAt] ?? 0.0) + (d['units'] as num).toDouble();
      }
    }

    List<double> donationsSeries = [];
    for (int i = 7; i >= 1; i--) {
      final dateStr = today.subtract(Duration(days: i)).toIso8601String().split('T')[0];
      donationsSeries.add(donationsMap[dateStr] ?? 0.0);
    }

    // Perform simple linear regression slope
    double slope = 0.0;
    double sumY = donationsSeries.reduce((a, b) => a + b);
    double avgDonations = sumY / 7.0;

    if (avgDonations > 0) {
      double sumX = 21.0; // 0+1+2+3+4+5+6
      double sumXY = 0.0;
      double sumXX = 91.0; // 0+1+4+9+16+25+36
      for (int i = 0; i < 7; i++) {
        sumXY += i * donationsSeries[i];
      }
      slope = (7.0 * sumXY - sumX * sumY) / (7.0 * sumXX - sumX * sumX);
      slope = slope / (avgDonations + 1.0); // Normalize against average
    }

    double donationTrendScore = 1.0 - slope;

    // 3. Accident Signal Score (Weight: 0.20)
    final bankDonations = _db.getTable('donation_records')
        .where((d) => d['bank_id'] == bankId)
        .toList();
    
    double accidentSeverityToday = 1.0;
    double maxHistoricalSeverity = 15.0;

    if (bankDonations.isNotEmpty) {
      // Sort by donated_at desc
      bankDonations.sort((a, b) => (b['donated_at'] as String).compareTo(a['donated_at'] as String));
      accidentSeverityToday = (bankDonations.first['accident_count_that_day'] as num? ?? 1.0).toDouble();
      
      int maxAcc = 0;
      for (var d in bankDonations) {
        final acc = d['accident_count_that_day'] as int? ?? 0;
        if (acc > maxAcc) maxAcc = acc;
      }
      maxHistoricalSeverity = maxAcc > 0 ? maxAcc.toDouble() : 15.0;
    }

    double accidentSignalScore = accidentSeverityToday / maxHistoricalSeverity;

    // 4. Rare Group Flag (Weight: 0.10)
    double rareGroupFlag = ['AB-', 'B-', 'O-'].contains(bloodGroup) ? 1.0 : 0.0;

    // 5. Expiry Pressure Score (Weight: 0.10)
    double expiryPressureScore = unitsAvailable > 0 ? (unitsExpiring3Days / unitsAvailable) : 1.0;

    // Clip all inputs between 0.0 and 1.0
    inventoryGapScore = inventoryGapScore.clamp(0.0, 1.0);
    donationTrendScore = donationTrendScore.clamp(0.0, 1.0);
    accidentSignalScore = accidentSignalScore.clamp(0.0, 1.0);
    expiryPressureScore = expiryPressureScore.clamp(0.0, 1.0);

    // Compute BSSI value
    double bssiVal = (
      inventoryGapScore * 0.35 +
      donationTrendScore * 0.25 +
      accidentSignalScore * 0.20 +
      rareGroupFlag * 0.10 +
      expiryPressureScore * 0.10
    ) * 100.0;

    bssiVal = double.parse(bssiVal.toStringAsFixed(1));

    // Save BSSI score to local database
    final newScore = {
      'bank_id': bankId,
      'blood_group': bloodGroup,
      'score': bssiVal,
      'inventory_gap_score': inventoryGapScore,
      'donation_trend_score': donationTrendScore,
      'accident_signal_score': accidentSignalScore,
      'rare_group_flag': rareGroupFlag,
      'expiry_pressure_score': expiryPressureScore,
      'computed_at': DateTime.now().toIso8601String(),
    };
    
    // Check if score already exists for computed_at date
    final existingScores = _db.getTable('bssi_scores');
    int? existingId;
    for (var s in existingScores) {
      if (s['bank_id'] == bankId && s['blood_group'] == bloodGroup) {
        // Just update the latest score rather than creating infinitely many rows for simplicity in memory
        existingId = s['score_id'] as int?;
        break;
      }
    }

    if (existingId != null) {
      await _db.update('bssi_scores', 'score_id', existingId, newScore);
    } else {
      await _db.insert('bssi_scores', newScore, 'score_id');
    }

    return {
      'bank_id': bankId,
      'blood_group': bloodGroup,
      'score': bssiVal,
      'factors': {
        'inventory_gap': double.parse(inventoryGapScore.toStringAsFixed(3)),
        'donation_trend': double.parse(donationTrendScore.toStringAsFixed(3)),
        'accident_signal': double.parse(accidentSignalScore.toStringAsFixed(3)),
        'rare_group': double.parse(rareGroupFlag.toStringAsFixed(3)),
        'expiry_pressure': double.parse(expiryPressureScore.toStringAsFixed(3))
      }
    };
  }

  // Updates all scores
  Future<void> updateAllBssiScores() async {
    await _db.init();
    final banks = _db.getTable('blood_banks');
    final bloodGroups = ['O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-'];
    for (var bank in banks) {
      final bankId = bank['bank_id'] as int;
      for (var bg in bloodGroups) {
        await computeBssi(bankId, bg);
      }
    }
  }

  // Haversine Distance Formula
  double calculateDistance(double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371; // Earth radius in km
    final double dLat = _toRadians(lat2 - lat1);
    final double dLng = _toRadians(lng2 - lng1);
    final double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) * cos(_toRadians(lat2)) *
        sin(dLng / 2) * sin(dLng / 2);
    final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  double _toRadians(double degree) {
    return degree * pi / 180;
  }

  // Rank eligible donors by priority score
  Future<List<Map<String, dynamic>>> rankEligibleDonors(int bankId, String bloodGroup) async {
    await _db.init();
    final banks = _db.getTable('blood_banks').where((b) => b['bank_id'] == bankId).toList();
    if (banks.isEmpty) return [];
    
    final bank = banks.first;
    final double bankLat = (bank['location_lat'] as num).toDouble();
    final double bankLng = (bank['location_lng'] as num).toDouble();

    final donors = _db.getTable('donors')
        .where((d) => d['blood_group'] == bloodGroup && d['is_eligible'] == true)
        .toList();

    final List<Map<String, dynamic>> rankedList = [];
    final today = DateTime.now();

    for (var donor in donors) {
      final double donorLat = (donor['location_lat'] as num).toDouble();
      final double donorLng = (donor['location_lng'] as num).toDouble();
      final double distance = calculateDistance(bankLat, bankLng, donorLat, donorLng);

      final double distTerm = 1.0 / max(0.1, distance);

      // Last donation date calculation
      DateTime lastDonationDate;
      if (donor['last_donation_date'] != null) {
        lastDonationDate = DateTime.parse(donor['last_donation_date'] as String);
      } else {
        lastDonationDate = today.subtract(const Duration(days: 90));
      }
      final int daysSince = today.difference(lastDonationDate).inDays;
      final double daysTerm = daysSince / 90.0;

      final double responseRate = (donor['response_rate'] as num? ?? 0.0).toDouble();

      final double priorityScore = (distTerm * 0.5) + (responseRate * 0.3) + (daysTerm * 0.2);
      final int eta = (distance * 2).toInt() + 5;

      rankedList.add({
        'donor': donor,
        'priority_score': double.parse(priorityScore.toStringAsFixed(4)),
        'distance_km': double.parse(distance.toStringAsFixed(2)),
        'eta_minutes': eta,
      });
    }

    rankedList.sort((a, b) => (b['priority_score'] as num).compareTo(a['priority_score'] as num));
    return rankedList.take(20).toList();
  }
}
