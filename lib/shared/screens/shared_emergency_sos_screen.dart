// lib/shared/screens/shared_emergency_sos_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:riskradar/utils/responsive.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:geolocator/geolocator.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_vibrate/flutter_vibrate.dart';
import 'package:riskradar/shared/security/input_sanitizer.dart';

class SharedEmergencySOSScreen extends StatefulWidget {
  final String? linkedContractorId;
  final String? currentSiteId;
  final bool isWorker;
  final bool isOfficer;

  const SharedEmergencySOSScreen({
    super.key,
    this.linkedContractorId,
    required this.currentSiteId,
    this.isWorker = true,
    this.isOfficer = false,
  });

  @override
  State<SharedEmergencySOSScreen> createState() =>
      _SharedEmergencySOSScreenState();
}

class _SharedEmergencySOSScreenState extends State<SharedEmergencySOSScreen>
    with SingleTickerProviderStateMixin {
  final SupabaseClient supabase = Supabase.instance.client;

  // ✅ Native platform channel to force STREAM_ALARM (bypasses silent mode)
  static const _alarmChannel = MethodChannel('com.example.riskradar/alarm');

  bool _isAlerting = false;
  double _pressProgress = 0.0;
  Timer? _pressTimer;
  Timer? _sirenLoopTimer;
  List<Map<String, dynamic>> _contacts = [];
  bool _loadingContacts = true;
  String? _userRole;
  bool _canVibrate = false;

  late AnimationController _pulseController;
  late AudioPlayer _audioPlayer;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _audioPlayer = AudioPlayer();
    _setupAudio();
    _checkVibration();
    _identifyUserAndFetchContacts();
  }

  Future<void> _checkVibration() async {
    try {
      final bool canVibrate = await Vibrate.canVibrate;
      setState(() => _canVibrate = canVibrate);
    } catch (e) {
      debugPrint("Vibration check error: $e");
    }
  }

  Future<void> _setupAudio() async {
    try {
      await _audioPlayer.setVolume(1.0);
      await _audioPlayer.setLoopMode(LoopMode.one);
    } catch (e) {
      debugPrint("Audio setup error: $e");
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _pressTimer?.cancel();
    _sirenLoopTimer?.cancel();
    _stopAlarm();
    _audioPlayer.dispose();
    super.dispose();
  }

  /// ✅ Force Android STREAM_ALARM via native channel — bypasses silent/vibrate
  Future<void> _forceAlarmVolume() async {
    try {
      await _alarmChannel.invokeMethod('setAlarmVolume');
    } catch (e) {
      debugPrint("Native alarm channel error: $e");
    }
  }

  Future<void> _startAlarm() async {
    // ✅ Step 1: Force alarm stream volume via native Android channel
    await _forceAlarmVolume();

    // ✅ Step 2: Play audio
    try {
      await _audioPlayer.setAudioSource(
        AudioSource.asset('assets/audio/sos_alarm.wav'),
      );
      await _audioPlayer.setVolume(1.0);
      await _audioPlayer.setLoopMode(LoopMode.one);
      await _audioPlayer.play();
    } catch (e) {
      debugPrint("Alarm start error: $e");
    }

    // ✅ Step 3: Start vibration loop
    if (_canVibrate) {
      _sirenLoopTimer = Timer.periodic(
        const Duration(milliseconds: 600),
        (_) => Vibrate.feedback(FeedbackType.heavy),
      );
    }
  }

  Future<void> _stopAlarm() async {
    try {
      await _audioPlayer.stop();
    } catch (e) {
      debugPrint("Alarm stop error: $e");
    }
    _sirenLoopTimer?.cancel();
    _sirenLoopTimer = null;
  }

  Future<void> _identifyUserAndFetchContacts() async {
    try {
      final userId = supabase.auth.currentUser!.id;
      final List<Map<String, dynamic>> loadedContacts = [];

      if (widget.isOfficer) {
        _userRole = "Officer / Contractor";

        final officerContacts = await supabase
            .from('officer_emergency_contacts')
            .select(
              'contact_name, relationship, personal, ambulance, fire_brigade',
            )
            .eq('officer_id', userId)
            .maybeSingle();

        if (officerContacts != null) {
          final personalNumbers = officerContacts['personal']
              ?.toString()
              .split(',')
              .map((number) => number.trim())
              .where((number) => number.isNotEmpty)
              .toList();
          final contactName = officerContacts['contact_name']
              ?.toString()
              .trim();
          final relationship = officerContacts['relationship']
              ?.toString()
              .trim();

          for (int index = 0; index < (personalNumbers?.length ?? 0); index++) {
            loadedContacts.add({
              'name':
                  contactName != null && contactName.isNotEmpty && index == 0
                  ? _capitalize(contactName)
                  : 'Emergency Contact ${index + 1}',
              'number': personalNumbers![index],
              'label':
                  relationship != null &&
                      relationship.isNotEmpty &&
                      index == 0
                  ? _capitalize(relationship)
                  : 'Personal Contact',
              'icon': Icons.person,
            });
          }

          _addServiceContact(
            loadedContacts,
            name: 'Ambulance',
            number: officerContacts['ambulance'],
            icon: Icons.medical_services,
          );
          _addServiceContact(
            loadedContacts,
            name: 'Fire Brigade',
            number: officerContacts['fire_brigade'],
            icon: Icons.local_fire_department,
          );
        }
      } else if (widget.isWorker) {
        _userRole = "Site Worker";

        final workerContactRes = await supabase
            .from('worker_emergency_contacts')
            .select('contact_name, phone, ambulance, fire_brigade')
            .eq('worker_id', userId)
            .maybeSingle();

        if (workerContactRes != null) {
          if (workerContactRes['phone'] != null &&
              workerContactRes['phone'].toString().isNotEmpty) {
            loadedContacts.add({
              'name': _capitalize(
                workerContactRes['contact_name'] ?? 'Personal Contact',
              ),
              'number': workerContactRes['phone'],
              'icon': Icons.person,
            });
          }
          if (workerContactRes['ambulance'] != null) {
            loadedContacts.add({
              'name': 'Ambulance',
              'number': workerContactRes['ambulance'],
              'icon': Icons.medical_services,
            });
          }
          if (workerContactRes['fire_brigade'] != null) {
            loadedContacts.add({
              'name': 'Fire Brigade',
              'number': workerContactRes['fire_brigade'],
              'icon': Icons.local_fire_department,
            });
          }
        }

        if (widget.linkedContractorId != null) {
          final hseWorkersRes = await supabase
              .from('hse_workers')
              .select('id, first_name, last_name')
              .eq('officer_uid', widget.linkedContractorId!);

          if (hseWorkersRes.isNotEmpty) {
            final hseIds = hseWorkersRes.map((w) => w['id']).toList();

            final hseContactRes = await supabase
                .from('hse_emergency_contacts')
                .select('supervisor, hse_worker_id')
                .inFilter('hse_worker_id', hseIds)
                .not('supervisor', 'is', null)
                .neq('supervisor', '')
                .limit(1)
                .maybeSingle();

            if (hseContactRes != null) {
              final relevantWorker = hseWorkersRes.firstWhere(
                (w) => w['id'] == hseContactRes['hse_worker_id'],
                orElse: () => hseWorkersRes.first,
              );

              final hseName =
                  "${relevantWorker['first_name']} ${relevantWorker['last_name']}";

              loadedContacts.insert(0, {
                'name': _capitalize(hseName),
                'number': hseContactRes['supervisor'],
                'label': 'Safety Inspector',
                'icon': Icons.security,
              });
            }
          }
        }
      } else {
        _userRole = "Safety Supervisor";

        final contacts = await supabase
            .from('hse_emergency_contacts')
            .select('contact_name, phone, ambulance, fire_brigade')
            .eq('hse_worker_id', userId)
            .maybeSingle();

        if (widget.linkedContractorId != null) {
          try {
            final contractorRes = await supabase
                .from('officers')
                .select('''
                  first_name,
                  last_name,
                  emergency:officer_emergency_contacts(supervisor)
                ''')
                .eq('id', widget.linkedContractorId!)
                .maybeSingle();

            if (contractorRes != null) {
              final fullName =
                  "${contractorRes['first_name'] ?? ''} ${contractorRes['last_name'] ?? ''}"
                      .trim();

              final emergencyList = contractorRes['emergency'] as List?;
              final supervisorPhone =
                  (emergencyList != null && emergencyList.isNotEmpty)
                  ? emergencyList.first['supervisor']
                  : null;

              if (supervisorPhone != null) {
                loadedContacts.insert(0, {
                  'name': fullName.isNotEmpty
                      ? _capitalize(fullName)
                      : 'Site Contractor',
                  'number': supervisorPhone,
                  'label': 'Contractor',
                  'icon': Icons.engineering,
                });
              }
            }
          } catch (e) {
            debugPrint("Error fetching contractor relational data: $e");
          }
        }

        if (contacts != null) {
          if (contacts['phone'] != null) {
            loadedContacts.add({
              'name': _capitalize(
                contacts['contact_name'] ?? 'Personal Contact',
              ),
              'number': contacts['phone'],
              'icon': Icons.person,
            });
          }
          if (contacts['ambulance'] != null) {
            loadedContacts.add({
              'name': 'Ambulance',
              'number': contacts['ambulance'],
              'icon': Icons.medical_services,
            });
          }
          if (contacts['fire_brigade'] != null) {
            loadedContacts.add({
              'name': 'Fire Brigade',
              'number': contacts['fire_brigade'],
              'icon': Icons.local_fire_department,
            });
          }
        }
      }

      if (mounted) {
        setState(() {
          _contacts = loadedContacts;
          _loadingContacts = false;
        });
      }
    } catch (e) {
      debugPrint("Error fetching contacts: $e");
      if (mounted) setState(() => _loadingContacts = false);
    }
  }

  void _addServiceContact(
    List<Map<String, dynamic>> contacts, {
    required String name,
    required dynamic number,
    required IconData icon,
  }) {
    final value = number?.toString().trim() ?? '';
    if (value.isEmpty) {
      return;
    }
    contacts.add({
      'name': name,
      'number': value,
      'label': 'Emergency Service',
      'icon': icon,
    });
  }

  String _capitalize(String text) {
    if (text.isEmpty) return "";
    return text
        .split(' ')
        .map(
          (word) => word.isNotEmpty
              ? word[0].toUpperCase() + word.substring(1).toLowerCase()
              : "",
        )
        .join(' ');
  }

  Future<void> _sendGlobalAlert() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final role = InputSanitizer.cleanText(
        _userRole ?? 'Worker',
        maxLength: 40,
      );
      final message = InputSanitizer.cleanText(
        'EMERGENCY: SOS triggered by $role',
        maxLength: 120,
      );

      final alertData = {
        'reporter_uid': user.id,
        'role': role,
        'alert_type': 'SOS',
        'latitude': position.latitude,
        'longitude': position.longitude,
        'status': 'ACTIVE',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'message': message,
      };

      if (widget.isOfficer && widget.currentSiteId == null) {
        // sites.officer_uid references officers.id. For a contractor,
        // the authenticated user UUID is therefore the managed-site owner ID.
        final officerUid = user.id;

        final sites = List<Map<String, dynamic>>.from(
          await supabase
              .from('sites')
              .select('id')
              .eq('officer_uid', officerUid),
        );

        if (sites.isEmpty) {
          throw StateError('No managed sites found for this contractor.');
        }

        await supabase.from('site_alerts').insert(
          sites
              .map((site) => {...alertData, 'site_id': site['id']})
              .toList(),
        );
      } else {
        await supabase.from('site_alerts').insert({
          ...alertData,
          'site_id': widget.currentSiteId,
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("🚨 GLOBAL ALERT SENT: All site personnel notified!"),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      debugPrint("Alert failed: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Emergency alert could not be broadcast. Please use the direct call contacts.',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _startPress() {
    _pressTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      setState(() {
        _pressProgress += 0.02;
        if (_pressProgress >= 1.0) {
          _pressProgress = 1.0;
          _triggerEmergency();
          _pressTimer?.cancel();
        }
      });
    });
  }

  void _cancelPress() {
    _pressTimer?.cancel();
    if (!_isAlerting) setState(() => _pressProgress = 0.0);
  }

  void _triggerEmergency() {
    setState(() => _isAlerting = true);
    _sendGlobalAlert();
    _startAlarm();
  }

  void _cancelEmergency() {
    setState(() {
      _isAlerting = false;
      _pressProgress = 0.0;
    });
    _stopAlarm();
  }

  @override
  Widget build(BuildContext context) {
    R.init(context);
    const goldColor = Color(0xFFE6A050);
    return Scaffold(
      backgroundColor: _isAlerting ? Colors.red.shade900 : Colors.white,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios,
            color: _isAlerting ? Colors.white : Colors.black,
          ),
          onPressed: () {
            if (_isAlerting) _stopAlarm();
            Navigator.pop(context);
          },
        ),
        title: Text(
          "Emergency SOS",
          style: TextStyle(
            color: _isAlerting ? Colors.white : Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(height: R.blockV * 2.5),
            _buildTriggerButton(goldColor),
            SizedBox(height: R.blockV * 2),

            // ✅ STOP button — only visible when alarm is active
            if (_isAlerting)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: R.blockH * 15),
                child: ElevatedButton.icon(
                  onPressed: _cancelEmergency,
                  icon: Icon(Icons.stop_circle_outlined),
                  label: Text(
                    "STOP ALARM",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.red.shade900,
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
              ),

            SizedBox(height: R.blockV * 2),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: R.blockH * 10),
              child: Text(
                _isAlerting
                    ? "Alarm active! Tap STOP ALARM to silence."
                    : "Hold to broadcast emergency alert to ALL users.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _isAlerting ? Colors.white70 : Colors.grey.shade600,
                  fontSize: R.blockH * 3.5,
                ),
              ),
            ),
            SizedBox(height: R.blockV * 5),
            _buildContactList(),
          ],
        ),
      ),
    );
  }

  Widget _buildTriggerButton(Color gold) {
    return Center(
      child: GestureDetector(
        onLongPressStart: (_) => _startPress(),
        onLongPressEnd: (_) => _cancelPress(),
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                return Container(
                  width: R.blockH * 64 + (20 * _pulseController.value),
                  height: R.blockV * 30 + (20 * _pulseController.value),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (_isAlerting ? Colors.red : gold).withValues(
                      alpha: (0.2 * (1 - _pulseController.value)),
                    ),
                  ),
                );
              },
            ),
            SizedBox(
              width: R.blockH * 56,
              height: R.blockV * 26.25,
              child: CircularProgressIndicator(
                value: _pressProgress,
                strokeWidth: 10,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation<Color>(
                  _isAlerting ? Colors.white : gold,
                ),
              ),
            ),
            Container(
              width: R.blockH * 48,
              height: R.blockV * 22.5,
              decoration: BoxDecoration(
                color: _isAlerting ? Colors.red : gold,
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 20,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isAlerting ? Icons.warning_amber_rounded : Icons.touch_app,
                    size: 50,
                    color: Colors.white,
                  ),
                  SizedBox(height: R.blockV * 1.25),
                  Text(
                    _isAlerting ? "HELP\nREQUESTED" : "HOLD TO\nALERT",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: R.blockH * 4.5,
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

  Widget _buildContactList() {
    return Container(
      padding: EdgeInsets.all(R.blockH * 6),
      width: double.infinity,
      decoration: BoxDecoration(
        color: _isAlerting
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.grey.shade50,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "DIRECT CALL CONTACTS",
            style: TextStyle(
              fontSize: R.blockH * 3,
              fontWeight: FontWeight.bold,
              color: _isAlerting ? Colors.white : Colors.grey.shade600,
            ),
          ),
          SizedBox(height: R.blockV * 2.5),
          if (_loadingContacts)
            Center(child: CircularProgressIndicator())
          else if (_contacts.isEmpty)
            Text(
              "No emergency contacts found.",
              style: TextStyle(color: Colors.grey),
            )
          else
            ..._contacts.map((c) => _buildContactTile(c, _isAlerting)),
          SizedBox(height: R.blockV * 2.5),
        ],
      ),
    );
  }

  Widget _buildContactTile(Map<String, dynamic> contact, bool isAlert) {
    String displayNum = contact['number'].toString();
    bool hasNum = displayNum.isNotEmpty && displayNum != "null";

    return Container(
      margin: EdgeInsets.only(bottom: R.blockV * 1.5),
      decoration: BoxDecoration(
        color: isAlert ? Colors.white.withValues(alpha: 0.15) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isAlert ? Colors.white24 : Colors.grey.shade200,
        ),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isAlert
              ? Colors.red.shade400
              : const Color(0xFFE6A050).withValues(alpha: 0.15),
          child: Icon(
            contact['icon'],
            color: isAlert ? Colors.white : const Color(0xFFE6A050),
          ),
        ),
        title: Text(
          contact['name'],
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: isAlert ? Colors.white : Colors.black87,
          ),
        ),
        subtitle: Text(
          hasNum
              ? "${contact['label'] ?? 'Contact'}: $displayNum"
              : "No number provided",
          style: TextStyle(
            color: isAlert ? Colors.white70 : Colors.grey,
            fontSize: R.blockH * 3,
          ),
        ),
        trailing: hasNum
            ? Icon(Icons.call, color: Colors.green)
            : Icon(Icons.do_not_disturb_on_rounded, color: Colors.grey),
        onTap: () {
          if (hasNum) FlutterPhoneDirectCaller.callNumber(displayNum);
        },
      ),
    );
  }
}
