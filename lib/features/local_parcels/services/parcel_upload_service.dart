import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ParcelUploadService {
  static final supabase = Supabase.instance.client;

  /// Uploads a list of local parcel image files to the 'parcel_images' bucket 
  /// concurrently (in parallel) and returns their public URLs once complete.
  /// Throws an error if any of the uploads fail.
  static Future<List<String>> uploadImages(List<dynamic> images) async {
    final List<String> urls = [];
    final List<Future<void>> uploadFutures = [];

    for (final img in images) {
      if (img is File) {
        final fileName = '${DateTime.now().millisecondsSinceEpoch}_${img.path.split(RegExp(r'[/\\]')).last}';
        final path = 'parcels/$fileName';
        
        final publicUrl = supabase.storage
            .from('parcel_images')
            .getPublicUrl(path);
        
        urls.add(publicUrl);

        uploadFutures.add(
          supabase.storage
              .from('parcel_images')
              .upload(
                path, 
                img, 
                fileOptions: const FileOptions(upsert: true),
              )
              .then((_) {
                debugPrint('PARCEL UPLOAD => Uploaded file successfully to $publicUrl');
              }),
        );
      } else if (img is String) {
        urls.add(img);
      }
    }

    // Wait for all parallel uploads to finish. If any upload fails, this throws.
    await Future.wait(uploadFutures);
    return urls;
  }
}
