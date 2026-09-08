import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:waydrop/models/transport_order.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/features/intercity/shared/navigation/intercity_home_navigator.dart';
import 'package:waydrop/features/local_rides/shared/navigation/local_ride_home_navigator.dart';

class RiderRatingScreen extends StatefulWidget {
  final TransportOrder order;
  final Map<String, dynamic>? riderData;

  /// Part 22: when true, the Partner is rating the User (rated_by='rider') instead of the
  /// default User-rates-Partner direction (rated_by='user'). [riderData] should then carry the
  /// passenger's own display name/photo (e.g. {'name': ..., 'rider_image': ...}) rather than the
  /// rider's — reusing the exact same screen/table for both directions per Part 22's instruction
  /// to reuse the existing review architecture.
  final bool ratedByRider;

  const RiderRatingScreen({
    super.key,
    required this.order,
    this.riderData,
    this.ratedByRider = false,
  });

  @override
  State<RiderRatingScreen> createState() => _RiderRatingScreenState();
}

class _RiderRatingScreenState extends State<RiderRatingScreen> {
  final supabase = Supabase.instance.client;
  final TextEditingController _commentController = TextEditingController();
  
  int _selectedRating = 5;
  final Set<String> _selectedTags = {};
  bool _isSubmitting = false;

  // Positive Tags (Rating 4-5). Issue 6B fix: when a Traveller/Rider rates the Passenger
  // (widget.ratedByRider == true), vehicle/driving categories make no sense -- the passenger
  // neither owns the vehicle nor drives. Every existing direction (passenger rates rider/
  // traveller, both local and intercity) keeps these exact original tags, unchanged.
  Map<String, String> get _positiveTags => widget.ratedByRider
      ? const {
          'On Time': 'on_time',
          'Good Behaviour': 'good_behaviour',
          'Respectful': 'respectful',
          'Easy to Communicate With': 'easy_to_communicate',
          'Clear Instructions': 'clear_instructions',
          'Cooperative': 'cooperative',
          'Ready at Pickup': 'ready_at_pickup',
          'Other': 'other',
        }
      : const {
          'Clean Vehicle': 'clean_vehicle',
          'Polite Behavior': 'polite_behavior',
          'Safe Driving': 'safe_driving',
          'On Time': 'on_time',
          'Other': 'other',
        };

  // Negative Tags (Rating 1-3) -- same role-aware split as _positiveTags above.
  Map<String, String> get _negativeTags => widget.ratedByRider
      ? const {
          'Late at Pickup': 'late_at_pickup',
          'Rude Behaviour': 'rude_behaviour',
          'Poor Communication': 'poor_communication',
          'Uncooperative': 'uncooperative',
          'Changed Plans Unexpectedly': 'changed_plans',
          'No-show': 'no_show',
          'Other': 'other',
        }
      : const {
          'Dirty Vehicle': 'dirty_vehicle',
          'Rude Behavior': 'rude_behavior',
          'Unsafe Driving': 'unsafe_driving',
          'Late Arrival': 'late_arrival',
          'Other': 'other',
        };

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  /// Task 4: every exit path must land back on the correct home dashboard (not the bare app root
  /// that `popUntil(isFirst)` used to overshoot to). Intercity trips land on the Intercity Home
  /// dashboard; local trips land on the Rider/User home shell depending on who's rating whom.
  void _returnHome(BuildContext context) {
    if (widget.order.isIntercity) {
      returnToIntercityHome(context, isTraveller: widget.ratedByRider);
    } else {
      returnToLocalRideHome(context, isRider: widget.ratedByRider);
    }
  }

  void _onStarTapped(int rating) {
    setState(() {
      _selectedRating = rating;
      // Clear tags because we switch between positive and negative tag groups
      _selectedTags.clear();
    });
  }

  void _toggleTag(String tagKey) {
    setState(() {
      if (_selectedTags.contains(tagKey)) {
        _selectedTags.remove(tagKey);
      } else {
        _selectedTags.add(tagKey);
      }
    });
  }

  Future<void> _submitRating() async {
    if (_isSubmitting) return;

    setState(() {
      _isSubmitting = true;
    });

    try {
      final user = supabase.auth.currentUser;
      if (user == null) {
        throw Exception('User is not authenticated');
      }

      if (widget.ratedByRider) {
        // Partner rating the User: current user must be the rider on this order.
        final riderCheck = await supabase
            .from('riders')
            .select('user_id')
            .eq('id', widget.order.riderId!)
            .maybeSingle();
        if (riderCheck == null || riderCheck['user_id'] != user.id) {
          throw Exception('Only the assigned travel partner can rate this passenger');
        }
      } else {
        // STRICT self-rating validation: query the riders table
        final riderCheck = await supabase
            .from('riders')
            .select('user_id')
            .eq('id', widget.order.riderId!)
            .maybeSingle();
        if (riderCheck != null && riderCheck['user_id'] == user.id) {
          throw Exception('You cannot rate yourself as a rider');
        }
      }

      // Map display tags to postgres enum values
      final activeTagMap = _selectedRating >= 4 ? _positiveTags : _negativeTags;
      final List<String> mappedTags = _selectedTags.map((tag) => activeTagMap[tag]!).toList();

      await supabase.from('rider_reviews').insert({
        'order_id': widget.order.id,
        'rider_id': widget.order.riderId,
        'user_id': widget.order.userId,
        'rating': _selectedRating,
        'tags': mappedTags,
        'rated_by': widget.ratedByRider ? 'rider' : 'user',
        'comment': _commentController.text.trim().isNotEmpty
            ? _commentController.text.trim()
            : null,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Thank you for your feedback!'),
            backgroundColor: Color(0xFF10B981),
          ),
        );
        // Take the user to the home screen directly as requested
        _returnHome(context);
      }
    } catch (e) {
      debugPrint('ERROR SUBMITTING REVIEW => $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to submit review: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Widget _riderInitial(String initial, bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF171A21) : const Color(0xFFEFF6FF),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.bold,
          color: Color(0xFF10B981),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final riderName = widget.riderData?['name']?.toString() ?? 'Drop Partner';
    final riderImage = widget.riderData?['rider_image']?.toString() ?? '';
    final initial = riderName.isNotEmpty ? riderName[0].toUpperCase() : 'R';
    
    // Choose active tags based on stars rating selection
    final activeTagsMap = _selectedRating >= 4 ? _positiveTags : _negativeTags;

    final isRide = widget.order.flowType == OrderFlowType.ride || widget.order.flowType == OrderFlowType.intercity;
    final headerTitle = widget.ratedByRider
        ? 'Rate your passenger'
        : (isRide ? 'How was your trip?' : 'How was your delivery?');

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1E222B) : Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.close_rounded,
            color: isDark ? Colors.white : const Color(0xFF0F172A),
          ),
          onPressed: () {
            // Dismiss rating screen and redirect to home
            _returnHome(context);
          },
        ),
        title: Text(
          headerTitle,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : const Color(0xFF0F172A),
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 12),
              
              // Circular Rider Avatar Image
              Container(
                height: 90,
                width: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF10B981),
                    width: 2.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.15 : 0.1),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: (riderImage.isNotEmpty && riderImage.startsWith('http'))
                      ? CachedNetworkImage(
                          imageUrl: riderImage,
                          fit: BoxFit.cover,
                          placeholder: (ctx, url) => const ImageSkeleton(shape: BoxShape.circle),
                          errorWidget: (ctx, url, err) => _riderInitial(initial, isDark),
                        )
                      : _riderInitial(initial, isDark),
                ),
              ),
              const SizedBox(height: 16),
              
              // Rider Name
              Text(
                riderName,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 24),
              
              // Star Selector Row
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (index) {
                  final starIndex = index + 1;
                  final isSelected = starIndex <= _selectedRating;
                  return GestureDetector(
                    onTap: () => _onStarTapped(starIndex),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6.0),
                      child: Icon(
                        Icons.star_rounded,
                        size: 42,
                        color: isSelected ? const Color(0xFFF59E0B) : (isDark ? Colors.white24 : Colors.grey.shade300),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 28),
              
              // Dynamic Feedback Tags wrap
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: activeTagsMap.keys.map((tag) {
                  final isSelected = _selectedTags.contains(tag);
                  final activeBg = isSelected
                      ? const Color(0xFF10B981).withValues(alpha: 0.15)
                      : (isDark ? const Color(0xFF171A21) : const Color(0xFFF8FAFC));
                  final activeBorder = isSelected
                      ? const Color(0xFF10B981)
                      : (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0));
                  final activeText = isSelected
                      ? const Color(0xFF10B981)
                      : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B));

                  return GestureDetector(
                    onTap: () => _toggleTag(tag),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: activeBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: activeBorder, width: 1.2),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          color: activeText,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 32),
              
              // Feedback textarea
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Leave feedback',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _commentController,
                maxLines: 4,
                cursorColor: const Color(0xFF10B981),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
                decoration: InputDecoration(
                  hintText: 'Type in here',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: isDark ? const Color(0xFF475569) : Colors.grey.shade400,
                  ),
                  filled: true,
                  fillColor: isDark ? const Color(0xFF171A21) : const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: Color(0xFF10B981),
                      width: 1.5,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              
              // Savings Container
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF171A21) : const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFDCFCE7),
                  ),
                ),
                child: Row(
                  children: [
                    const Text('💰', style: TextStyle(fontSize: 18)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        isRide ? "You just saved money by this ride" : "You just saved money by this delivery",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF15803D),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              
              // Action Button (Continue)
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: const Color(0xFF2563EB), // Premium Blue
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: _isSubmitting ? null : _submitRating,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text(
                          'Continue',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
