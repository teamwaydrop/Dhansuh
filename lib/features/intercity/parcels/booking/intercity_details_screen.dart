import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:waydrop/features/local_parcels/services/parcel_upload_service.dart';
import 'package:waydrop/shared/helpers/time_format_helper.dart';
import 'package:waydrop/features/intercity/parcels/booking/intercity_booking_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_location_screen.dart';

class IntercityDetailsScreen extends StatefulWidget {
  final String orderType; // 'local_parcel' or 'intercity_parcel'
  final String? pickupAddress;
  final String? destinationAddress;
  final double? pickupLat;
  final double? pickupLng;
  final double? destinationLat;
  final double? destinationLng;
  final double? totalDistanceMeters;
  final double? durationSeconds;
  final List<Map<String, dynamic>>? routePoints;

  final String? pickupCity;
  final String? destinationCity;

  final String? receiverName;
  final String? receiverPhone;
  final String? parcelType;
  final String? weightCategory;
  final String? specialInstructions;

  const IntercityDetailsScreen({
    super.key,
    required this.orderType,
    this.pickupAddress,
    this.destinationAddress,
    this.pickupLat,
    this.pickupLng,
    this.destinationLat,
    this.destinationLng,
    this.totalDistanceMeters,
    this.durationSeconds,
    this.routePoints,
    this.pickupCity,
    this.destinationCity,
    this.receiverName,
    this.receiverPhone,
    this.parcelType,
    this.weightCategory,
    this.specialInstructions,
  });

  @override
  State<IntercityDetailsScreen> createState() => _IntercityDetailsScreenState();
}

class _IntercityDetailsScreenState extends State<IntercityDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _instructionsController = TextEditingController();

  String _selectedParcelType = 'other';
  double _selectedWeight = 5.0; // Default: 5.0 kg
  DateTime _selectedTravelDate = DateTime.now().add(const Duration(days: 1));
  bool _declaredNoHarmfulItems = false;

  // Route state details
  String? _pickupAddress;
  double? _pickupLat;
  double? _pickupLng;
  String? _pickupCity;
  String? _destinationAddress;
  double? _destinationLat;
  double? _destinationLng;
  String? _destinationCity;
  double? _totalDistanceMeters;
  double? _durationSeconds;
  List<Map<String, dynamic>>? _routePoints;

  @override
  void initState() {
    super.initState();
    if (widget.receiverName != null) {
      _nameController.text = widget.receiverName!;
    }
    if (widget.receiverPhone != null) {
      _phoneController.text = widget.receiverPhone!;
    }
    if (widget.specialInstructions != null) {
      _instructionsController.text = widget.specialInstructions!;
    }
    if (widget.parcelType != null) {
       final val = widget.parcelType!.toLowerCase().trim();
       if (val == 'others' || val == 'other') {
         _selectedParcelType = 'other';
       } else if (['document', 'electronics', 'clothes', 'food'].contains(val)) {
         _selectedParcelType = val;
       } else {
         _selectedParcelType = 'other';
       }
     }
    if (widget.weightCategory != null) {
      final category = widget.weightCategory!;
      if (category.contains('_')) {
        final part = category.split('_')[0];
        _selectedWeight = (double.tryParse(part) ?? 5.0).clamp(0.5, 50.0);
      } else {
        _selectedWeight = (double.tryParse(category) ?? 5.0).clamp(0.5, 50.0);
      }
    }
    // Initialize route state variables
    _pickupAddress = widget.pickupAddress;
    _pickupLat = widget.pickupLat;
    _pickupLng = widget.pickupLng;
    _pickupCity = widget.pickupCity;
    _destinationAddress = widget.destinationAddress;
    _destinationLat = widget.destinationLat;
    _destinationLng = widget.destinationLng;
    _destinationCity = widget.destinationCity;
    _totalDistanceMeters = widget.totalDistanceMeters;
    _durationSeconds = widget.durationSeconds;
    if (widget.routePoints != null) {
      _routePoints = List<Map<String, dynamic>>.from(widget.routePoints!);
    }

    _fetchRecentContacts();
  }
  
  final List<File> _selectedImages = [];
  final ImagePicker _picker = ImagePicker();
  bool _imageUploading = false;
  List<String> _uploadedUrls = [];
  List<Map<String, String>> _recentContacts = [];

  Future<void> _selectRouteLocations() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => IntercityLocationScreen(
          orderType: widget.orderType,
          isPickerMode: true,
          initialPickupAddress: _pickupAddress,
          initialPickupLat: _pickupLat,
          initialPickupLng: _pickupLng,
          initialDestinationAddress: _destinationAddress,
          initialDestinationLat: _destinationLat,
          initialDestinationLng: _destinationLng,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _pickupAddress = result['pickupAddress'];
        _pickupLat = result['pickupLat'];
        _pickupLng = result['pickupLng'];
        _pickupCity = result['pickupCity'];
        _destinationAddress = result['destinationAddress'];
        _destinationLat = result['destinationLat'];
        _destinationLng = result['destinationLng'];
        _destinationCity = result['destinationCity'];
        _totalDistanceMeters = result['distanceMeters'];
        _durationSeconds = result['durationSeconds'];
        _routePoints = List<Map<String, dynamic>>.from(result['routePoints']);
      });
    }
  }

  void _selectDateCupertino(BuildContext context, Color primaryColor, Color textCol, Color subTextCol, Color borderCol) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF131929) : Colors.white,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) {
        DateTime tempPickedDate = _selectedTravelDate;
        return Container(
          height: 380,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: subTextCol.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Select Departure Date',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: textCol,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: CupertinoTheme(
                  data: CupertinoThemeData(
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: textCol,
                      ),
                    ),
                  ),
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: tempPickedDate,
                    minimumDate: DateTime.now(),
                    maximumDate: DateTime.now().add(const Duration(days: 30)),
                    onDateTimeChanged: (DateTime date) {
                      tempPickedDate = date;
                    },
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      _selectedTravelDate = DateTime(
                        tempPickedDate.year,
                        tempPickedDate.month,
                        tempPickedDate.day,
                        _selectedTravelDate.hour,
                        _selectedTravelDate.minute,
                      );
                    });
                    Navigator.pop(context);
                  },
                  child: const Text(
                    'Confirm Date',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _selectTimeCupertino(BuildContext context, Color primaryColor, Color textCol, Color subTextCol, Color borderCol) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF131929) : Colors.white,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) {
        DateTime tempPickedTime = _selectedTravelDate;
        return Container(
          height: 380,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: subTextCol.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Select Departure Time',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: textCol,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: CupertinoTheme(
                  data: CupertinoThemeData(
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: textCol,
                      ),
                    ),
                  ),
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    initialDateTime: tempPickedTime,
                    onDateTimeChanged: (DateTime date) {
                      tempPickedTime = date;
                    },
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      _selectedTravelDate = DateTime(
                        _selectedTravelDate.year,
                        _selectedTravelDate.month,
                        _selectedTravelDate.day,
                        tempPickedTime.hour,
                        tempPickedTime.minute,
                      );
                    });
                    Navigator.pop(context);
                  },
                  child: const Text(
                    'Confirm Time',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _fetchRecentContacts() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final deletedPhones = prefs.getStringList('deleted_receiver_phones') ?? [];
      
      final response = await Supabase.instance.client
          .from('orders')
          .select('receiver_name, receiver_phone')
          .eq('user_id', user.id)
          .not('receiver_name', 'is', null)
          .not('receiver_phone', 'is', null)
          .order('created_at', ascending: false)
          .limit(15);
      
      final List<Map<String, String>> list = [];
      final Set<String> seenPhones = {};
      for (var item in response) {
        final name = item['receiver_name']?.toString().trim();
        final phone = item['receiver_phone']?.toString().trim();
        if (name != null && name.isNotEmpty && phone != null && phone.isNotEmpty) {
          if (!seenPhones.contains(phone) && !deletedPhones.contains(phone)) {
            seenPhones.add(phone);
            list.add({'name': name, 'phone': phone});
          }
        }
      }
      if (mounted) {
        setState(() {
          _recentContacts = list.take(3).toList();
        });
      }
    } catch (e) {
      debugPrint('Error fetching recent contacts: $e');
    }
  }

  final List<Map<String, dynamic>> _parcelTypes = [
    {'value': 'document', 'label': 'Documents', 'icon': Icons.description_outlined},
    {'value': 'electronics', 'label': 'Electronics', 'icon': Icons.bolt_rounded},
    {'value': 'clothes', 'label': 'Clothes', 'icon': Icons.checkroom_rounded},
    {'value': 'food', 'label': 'Food', 'icon': Icons.fastfood_rounded},
    {'value': 'other', 'label': 'Other', 'icon': Icons.inventory_2_outlined},
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _uploadSelectedImages(List<File> files) async {
    setState(() {
      _imageUploading = true;
    });
    try {
      final urls = await ParcelUploadService.uploadImages(files);
      if (urls.isNotEmpty) {
        setState(() {
          _uploadedUrls.addAll(urls);
        });
      }
    } catch (e) {
      debugPrint('UPLOAD ERROR => $e');
      _showSnackBar('Failed to upload package photo: $e. Please try again.');
      setState(() {
        _selectedImages.removeWhere((file) => files.contains(file));
      });
    } finally {
      setState(() {
        _imageUploading = false;
      });
    }
  }

  Future<void> _pickFromCamera() async {
    if (_selectedImages.length >= 5) {
      _showSnackBar('You can attach a maximum of 5 photos.');
      return;
    }
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (image != null) {
        final file = File(image.path);
        setState(() {
          _selectedImages.add(file);
        });
        await _uploadSelectedImages([file]);
      }
    } catch (e) {
      _showSnackBar('Camera access error: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    if (_selectedImages.length >= 5) {
      _showSnackBar('You can attach a maximum of 5 photos.');
      return;
    }
    try {
      final List<XFile> images = await _picker.pickMultiImage(
        imageQuality: 70,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (images.isNotEmpty) {
        final List<File> files = [];
        for (var image in images) {
          if (_selectedImages.length + files.length >= 5) {
            _showSnackBar('Maximum limit of 5 photos reached.');
            break;
          }
          files.add(File(image.path));
        }
        if (files.isNotEmpty) {
          setState(() {
            _selectedImages.addAll(files);
          });
          await _uploadSelectedImages(files);
        }
      }
    } catch (e) {
      _showSnackBar('Gallery access error: $e');
    }
  }

  void _removeSelectedImage(int index) {
    setState(() {
      _selectedImages.removeAt(index);
      if (_uploadedUrls.length > index) {
        _uploadedUrls.removeAt(index);
      }
    });
  }

  Future<void> _pickContact() async {
    try {
      if (await FlutterContacts.requestPermission(readonly: true)) {
        final contact = await FlutterContacts.openExternalPick();
        if (contact != null) {
          final fullContact = await FlutterContacts.getContact(contact.id);
          if (fullContact != null) {
            final name = fullContact.displayName;
            String phone = '';
            
            if (fullContact.phones.isNotEmpty) {
              if (fullContact.phones.length > 1) {
                if (!mounted) return;
                final selectedNumber = await showModalBottomSheet<String>(
                  context: context,
                  backgroundColor: Colors.transparent,
                  builder: (context) {
                    final isDark = Theme.of(context).brightness == Brightness.dark;
                    final sheetBg = isDark ? const Color(0xFF1E293B) : Colors.white;
                    final textCol = isDark ? Colors.white : const Color(0xFF0F172A);
                    final subCol = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
                    final borderCol = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
                    
                    return Container(
                      decoration: BoxDecoration(
                        color: sheetBg,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: Container(
                              width: 38,
                              height: 4,
                              decoration: BoxDecoration(
                                color: subCol.withOpacity(0.3),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'Select Phone Number',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: textCol,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '$name has multiple phone numbers. Please pick one:',
                            style: TextStyle(fontSize: 12, color: subCol),
                          ),
                          const SizedBox(height: 18),
                          Flexible(
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: fullContact.phones.length,
                              itemBuilder: (context, index) {
                                final p = fullContact.phones[index];
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                    border: Border.all(color: borderCol),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: ListTile(
                                    title: Text(
                                      p.number,
                                      style: TextStyle(
                                        color: textCol,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                    subtitle: Text(
                                      p.label.name.toUpperCase(),
                                      style: TextStyle(color: subCol, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                    trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 12),
                                    onTap: () => Navigator.pop(context, p.number),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
                if (selectedNumber != null) {
                  phone = selectedNumber;
                }
              } else {
                phone = fullContact.phones.first.number;
              }
              
              if (phone.isNotEmpty) {
                // Strip all non-digit formatting
                phone = phone.replaceAll(RegExp(r'[^0-9]'), '');
                if (phone.length > 10) {
                  phone = phone.substring(phone.length - 10);
                }
              }
            }
            
            setState(() {
              _nameController.text = name;
              if (phone.isNotEmpty) {
                _phoneController.text = phone;
              }
            });
          }
        }
      } else {
        _showSnackBar('Contact permission denied. Please allow contacts access in settings.');
      }
    } catch (e) {
      _showSnackBar('Error choosing contact: $e');
    }
  }

  void _showSnackBar(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  Future<void> _submitDetails() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_declaredNoHarmfulItems) {
      _showSnackBar('Please accept the safety declaration to continue!');
      return;
    }

    if (_selectedImages.isEmpty) {
      _showSnackBar('Please attach a photo of your package to continue!');
      return;
    }

    if (_imageUploading) {
      _showSnackBar('Please wait for the photo upload to complete!');
      return;
    }

    if (_uploadedUrls.isEmpty) {
      _showSnackBar('Photo upload in progress or failed. Please re-attach.');
      return;
    }

    if (_pickupAddress == null || _destinationAddress == null) {
      _showSnackBar('Please select pickup and drop locations to continue!');
      return;
    }

    if (_selectedTravelDate.isBefore(DateTime.now())) {
      _showSnackBar('Please select a departure date and time in the future!');
      return;
    }

    final String combinedInstructions = _instructionsController.text.trim();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => IntercityBookingScreen(
          orderType: widget.orderType,
          pickupAddress: _pickupAddress!,
          destinationAddress: _destinationAddress!,
          pickupLat: _pickupLat!,
          pickupLng: _pickupLng!,
          destinationLat: _destinationLat!,
          destinationLng: _destinationLng!,
          totalDistanceMeters: _totalDistanceMeters!,
          durationSeconds: _durationSeconds!,
          routePoints: _routePoints!,
          receiverName: _nameController.text.trim(),
          receiverPhone: _phoneController.text.trim(),
          parcelType: _selectedParcelType,
          weightCategory: _selectedWeight.round().toString(),
          specialInstructions: combinedInstructions,
          parcelImages: _uploadedUrls,
          travelDate: _selectedTravelDate,
          pickupCity: _pickupCity,
          destinationCity: _destinationCity,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Theme colors
    final screenBg = isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF171A21) : Colors.white;
    final textCol = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextCol = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderCol = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final inputBg = isDark ? const Color(0xFF0C101C) : const Color(0xFFF1F5F9);
    
    final primaryColor = const Color(0xFF10B981); // Emerald Green
    final accentOrange = const Color(0xFFFF4E25); // Premium Orange

    return PopScope(
      canPop: !_imageUploading,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _imageUploading) {
          _showSnackBar('Please wait while photo upload is in progress.');
        }
      },
      child: Scaffold(
        backgroundColor: screenBg,
        appBar: AppBar(
          backgroundColor: cardBg,
          elevation: 0.5,
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: _imageUploading ? textCol.withOpacity(0.3) : textCol,
              size: 18,
            ),
            onPressed: _imageUploading ? null : () => Navigator.pop(context),
          ),
          title: Text(
            'Parcel Specifications',
            style: TextStyle(
              color: textCol,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          centerTitle: true,
        ),
        // Keep true to scroll nicely when keyboard appears, but button will scroll naturally!
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              physics: const ClampingScrollPhysics(),
              children: [
                    // =====================================================
                    // 1. CHOOSE ROUTE
                    // =====================================================
                    Row(
                      children: [
                        Icon(Icons.map_rounded, size: 16, color: primaryColor),
                        const SizedBox(width: 8),
                        Text(
                          'CHOOSE ROUTE',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: subTextCol,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: borderCol),
                      ),
                      child: Column(
                        children: [
                          // Pickup Selector
                          InkWell(
                            onTap: _selectRouteLocations,
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF0C101C) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: borderCol),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.circle, color: Color(0xFF10B981), size: 8),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _pickupAddress ?? 'Select Pickup Location',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: _pickupAddress != null ? textCol : textCol.withOpacity(0.4),
                                      ),
                                    ),
                                  ),
                                  Icon(Icons.edit_rounded, size: 14, color: textCol.withOpacity(0.4)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          // Drop Selector
                          InkWell(
                            onTap: _selectRouteLocations,
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF0C101C) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: borderCol),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.location_on_rounded, color: Color(0xFFFF4E25), size: 12),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _destinationAddress ?? 'Select Drop Location',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: _destinationAddress != null ? textCol : textCol.withOpacity(0.4),
                                      ),
                                    ),
                                  ),
                                  Icon(Icons.edit_rounded, size: 14, color: textCol.withOpacity(0.4)),
                                ],
                              ),
                            ),
                          ),
                          if (_totalDistanceMeters != null && _durationSeconds != null) ...[
                            const SizedBox(height: 12),
                            Divider(height: 1, color: borderCol),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.directions_car_rounded, color: primaryColor, size: 16),
                                    const SizedBox(width: 6),
                                    Text(
                                      '${(_totalDistanceMeters! / 1000).toStringAsFixed(1)} km',
                                      style: TextStyle(
                                        color: textCol,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                Container(
                                  width: 1,
                                  height: 14,
                                  color: borderCol,
                                ),
                                Row(
                                  children: [
                                    Icon(Icons.schedule_rounded, color: primaryColor, size: 16),
                                    const SizedBox(width: 6),
                                    Text(
                                      _durationSeconds! >= 3600
                                          ? '${(_durationSeconds! / 3600).toStringAsFixed(1)} hours'
                                          : '${(_durationSeconds! / 60).toStringAsFixed(0)} mins',
                                      style: TextStyle(
                                        color: textCol,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    // =====================================================
                    // 1. RECEIVER DETAILS
                    // =====================================================
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.person_rounded, size: 16, color: primaryColor),
                            const SizedBox(width: 8),
                            Text(
                              'RECEIVER DETAILS',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: subTextCol,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ],
                        ),
                        TextButton.icon(
                          onPressed: _pickContact,
                          icon: Icon(Icons.contacts_rounded, size: 13, color: primaryColor),
                          label: Text(
                            'Choose Contact',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: primaryColor,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                    if (_recentContacts.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 38,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: _recentContacts.length,
                          physics: const ClampingScrollPhysics(),
                          itemBuilder: (context, index) {
                            final c = _recentContacts[index];
                            final contactName = c['name'] ?? '';
                            final contactPhone = c['phone'] ?? '';
                            final initials = contactName.isNotEmpty ? contactName.substring(0, 1).toUpperCase() : '?';
                            return Container(
                              margin: const EdgeInsets.only(right: 8),
                              child: GestureDetector(
                                onLongPress: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('Delete Recent Contact'),
                                      content: Text('Are you sure you want to remove $contactName from recents?'),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.pop(context, true),
                                          child: const Text('Delete', style: TextStyle(color: Colors.red)),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    final prefs = await SharedPreferences.getInstance();
                                    final deleted = prefs.getStringList('deleted_receiver_phones') ?? [];
                                    if (contactPhone.isNotEmpty && !deleted.contains(contactPhone)) {
                                      deleted.add(contactPhone);
                                      await prefs.setStringList('deleted_receiver_phones', deleted);
                                    }
                                    _fetchRecentContacts();
                                    _nameController.clear();
                                    _phoneController.clear();
                                  }
                                },
                                child: InputChip(
                                  avatar: CircleAvatar(
                                    backgroundColor: primaryColor.withOpacity(0.2),
                                    child: Text(
                                      initials,
                                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: primaryColor),
                                    ),
                                  ),
                                  label: Text(contactName),
                                  labelStyle: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: textCol,
                                  ),
                                  backgroundColor: cardBg,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(color: borderCol),
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _nameController.text = contactName;
                                      _phoneController.text = contactPhone;
                                    });
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: borderCol),
                      ),
                      child: Column(
                        children: [
                          _buildFormTextField(
                            controller: _nameController,
                            label: 'Receiver\'s Name',
                            hint: 'Enter full name',
                            icon: Icons.person_outline_rounded,
                            textCol: textCol,
                            borderCol: borderCol,
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Please enter receiver\'s name';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),
                          _buildFormTextField(
                            controller: _phoneController,
                            label: 'Mobile Number',
                            hint: 'Enter 10-digit number',
                            icon: Icons.phone_android_rounded,
                            textCol: textCol,
                            borderCol: borderCol,
                            keyboardType: TextInputType.phone,
                            inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(10),
                            ],
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Please enter phone number';
                              }
                              if (val.trim().length < 10) {
                                return 'Please enter a valid 10-digit number';
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // =====================================================
                    // 2. PACKAGE DETAILS & WEIGHT CATEGORY
                    // =====================================================
                    Row(
                      children: [
                        Icon(Icons.inventory_2_rounded, size: 16, color: primaryColor),
                        const SizedBox(width: 8),
                        Text(
                          'PACKAGE SPECIFICATIONS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: subTextCol,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: borderCol),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Dropdown for Package Type
                          Text(
                            'Package Type',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: subTextCol),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: inputBg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: borderCol),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedParcelType,
                                isExpanded: true,
                                icon: Icon(Icons.keyboard_arrow_down_rounded, color: subTextCol),
                                dropdownColor: cardBg,
                                items: _parcelTypes.map((type) {
                                  return DropdownMenuItem<String>(
                                    value: type['value'],
                                    child: Text(
                                      type['label']!,
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: textCol),
                                    ),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() {
                                      _selectedParcelType = val;
                                    });
                                  }
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),

                          // Slider for weight selection from 0.5 to 50kg
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Package Weight',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: subTextCol),
                              ),
                              Text(
                                '${_selectedWeight.toStringAsFixed(1)} kg',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: primaryColor),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SliderTheme(
                            data: SliderThemeData(
                              activeTrackColor: primaryColor,
                              inactiveTrackColor: borderCol,
                              thumbColor: primaryColor,
                              overlayColor: primaryColor.withValues(alpha: 0.12),
                              valueIndicatorColor: primaryColor,
                              valueIndicatorTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                            child: Slider(
                              value: _selectedWeight,
                              min: 0.5,
                              max: 50.0,
                              divisions: 99,
                              label: '${_selectedWeight.toStringAsFixed(1)} kg',
                              onChanged: (val) {
                                setState(() {
                                  _selectedWeight = val;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // =====================================================
                    // 3. TRAVEL DATE & TIME
                    // =====================================================
                    Row(
                      children: [
                        Icon(Icons.calendar_month_rounded, size: 16, color: primaryColor),
                        const SizedBox(width: 8),
                        Text(
                          'TRAVEL DATE & TIME',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: subTextCol,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: borderCol),
                      ),
                      child: Row(
                        children: [
                          // Date Picker Box
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Departure Date', style: TextStyle(color: subTextCol, fontSize: 11, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                GestureDetector(
                                  onTap: () => _selectDateCupertino(
                                      context,
                                      primaryColor,
                                      textCol,
                                      subTextCol,
                                      borderCol,
                                    ),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                    decoration: BoxDecoration(
                                      color: inputBg,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: borderCol),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(Icons.calendar_today_rounded, color: primaryColor, size: 16),
                                        const SizedBox(width: 8),
                                        Text(
                                          "${_selectedTravelDate.day.toString().padLeft(2, '0')}/${_selectedTravelDate.month.toString().padLeft(2, '0')}/${_selectedTravelDate.year}",
                                          style: TextStyle(color: textCol, fontSize: 13, fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Time Picker Box
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Departure Time', style: TextStyle(color: subTextCol, fontSize: 11, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                GestureDetector(
                                  onTap: () => _selectTimeCupertino(
                                      context,
                                      primaryColor,
                                      textCol,
                                      subTextCol,
                                      borderCol,
                                    ),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                    decoration: BoxDecoration(
                                      color: inputBg,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: borderCol),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(Icons.access_time_rounded, color: primaryColor, size: 16),
                                        const SizedBox(width: 8),
                                        Text(
                                          TimeFormatHelper.formatTime12Hour(_selectedTravelDate),
                                          style: TextStyle(color: textCol, fontSize: 13, fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // =====================================================
                    // 3. PHOTO UPLOADER (CLEAN PIC CARD)
                    // =====================================================
                    Row(
                      children: [
                        Icon(Icons.camera_alt_rounded, size: 16, color: primaryColor),
                        const SizedBox(width: 8),
                        Text(
                          'COURIER PHOTO & SPECIAL NOTES',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: subTextCol,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: borderCol),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(
                                child: Text(
                                  'Package Photos (Required) *',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: subTextCol),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                '${_selectedImages.length} / 5 photos',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                  color: _selectedImages.isEmpty ? Colors.orange : const Color(0xFF10B981),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              // Camera Button
                              InkWell(
                                onTap: _pickFromCamera,
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  width: 50,
                                  height: 50,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981).withValues(alpha: 0.08),
                                    border: Border.all(color: const Color(0xFF10B981), width: 1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(Icons.camera_alt_rounded, color: Color(0xFF10B981), size: 18),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Gallery Button
                              InkWell(
                                onTap: _pickFromGallery,
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  width: 50,
                                  height: 50,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF3B82F6).withValues(alpha: 0.08),
                                    border: Border.all(color: const Color(0xFF3B82F6), width: 1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(Icons.photo_library_rounded, color: Color(0xFF3B82F6), size: 18),
                                ),
                              ),
                              const SizedBox(width: 10),
                              // Preview List
                              if (_selectedImages.isNotEmpty)
                                Expanded(
                                  child: SizedBox(
                                    height: 50,
                                    child: ListView.builder(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: _selectedImages.length,
                                      itemBuilder: (context, idx) {
                                        return Stack(
                                          children: [
                                            Container(
                                              margin: const EdgeInsets.only(right: 8),
                                              width: 50,
                                              height: 50,
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(8),
                                                border: Border.all(color: borderCol),
                                                image: DecorationImage(
                                                  image: FileImage(_selectedImages[idx]),
                                                  fit: BoxFit.cover,
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              top: 0,
                                              right: 10,
                                              child: GestureDetector(
                                                onTap: () => _removeSelectedImage(idx),
                                                child: Container(
                                                  padding: const EdgeInsets.all(2),
                                                  decoration: const BoxDecoration(
                                                    color: Colors.black,
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: const Icon(
                                                    Icons.close_rounded,
                                                    size: 10,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (_imageUploading) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const SizedBox(
                                  width: 12, height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF10B981)),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Uploading photos...',
                                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: subTextCol),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 18),

                          // Courier Special Notes input
                          _buildFormTextField(
                            controller: _instructionsController,
                            label: 'Delivery Instructions (Optional)',
                            hint: 'e.g. Leave with security guards, fragile package...',
                            icon: Icons.notes_rounded,
                            textCol: textCol,
                            borderCol: borderCol,
                            maxLines: 2,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Safety Declaration Checkbox
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 24,
                          width: 24,
                          child: Checkbox(
                            value: _declaredNoHarmfulItems,
                            activeColor: primaryColor,
                            onChanged: (val) {
                              setState(() {
                                _declaredNoHarmfulItems = val ?? false;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'I declare that this parcel does not contain any illegal, dangerous, or harmful items.',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: textCol,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),

                    // =====================================================
                    // 4. CONTINUE BUTTON (SCROLLABLE child to prevent keyboard popping)
                    // =====================================================
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _submitDetails,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentOrange,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          elevation: 4,
                          shadowColor: accentOrange.withOpacity(0.3),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Continue',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.2,
                              ),
                            ),
                            SizedBox(width: 8),
                            Icon(Icons.arrow_forward_rounded, size: 16, color: Colors.white),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
      ),
    ));
  }

  // Styled Form Input fields
  Widget _buildFormTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required Color textCol,
    required Color borderCol,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    String? Function(String?)? validator,
    List<TextInputFormatter>? inputFormatters,
    Widget? suffixIcon,
  }) {
    final isDark = borderCol.value == 0xFF1E293B;
    final primaryColor = const Color(0xFF10B981);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: textCol.withOpacity(0.65)),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: maxLines,
          validator: validator,
          inputFormatters: inputFormatters,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: textCol,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: isDark ? const Color(0xFF0C101C) : const Color(0xFFF1F5F9),
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textCol.withOpacity(0.35),
            ),
            prefixIcon: Icon(icon, size: 16, color: textCol.withOpacity(0.4)),
            suffixIcon: suffixIcon,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: borderCol, width: 1.0),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: primaryColor, width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Colors.red, width: 1.0),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Colors.red, width: 1.5),
            ),
            errorStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Colors.red),
          ),
        ),
      ],
    );
  }
}
