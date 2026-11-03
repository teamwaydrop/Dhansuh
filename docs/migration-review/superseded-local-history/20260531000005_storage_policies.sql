-- Ensure the 'parcel_images' bucket exists and is public
INSERT INTO storage.buckets (id, name, public)
VALUES ('parcel_images', 'parcel_images', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- Drop existing policies if they exist to avoid duplicate conflicts
DROP POLICY IF EXISTS "Allow authenticated users to upload parcel images" ON storage.objects;
DROP POLICY IF EXISTS "Allow public to view parcel images" ON storage.objects;
DROP POLICY IF EXISTS "Allow users to update own parcel images" ON storage.objects;
DROP POLICY IF EXISTS "Allow users to delete own parcel images" ON storage.objects;

-- Create policies on storage.objects for parcel_images bucket
CREATE POLICY "Allow authenticated users to upload parcel images"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'parcel_images');

CREATE POLICY "Allow public to view parcel images"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'parcel_images');

CREATE POLICY "Allow users to update own parcel images"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'parcel_images' AND auth.uid()::text = owner_id);

CREATE POLICY "Allow users to delete own parcel images"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'parcel_images' AND auth.uid()::text = owner_id);
