# Keep rules for release builds (isMinifyEnabled / isShrinkResources).
#
# Without these, R8 can strip or rename classes in the bundled local AARs
# (Ola Maps SDK, Ola Maps Navigation SDK, Places SDK) and the Cashfree
# payment SDK, since none of them ship their own consumer ProGuard rules.
# This only ever surfaces in the signed release build (debug builds aren't
# minified), which is exactly the build used for Play Store / internal
# testing uploads.

# Preserve attributes needed for correct behavior and readable stack traces.
-keepattributes Signature,*Annotation*,SourceFile,LineNumberTable,Exceptions,InnerClasses

# --- Ola Maps SDK (android/app/libs/OlaMapSdk-*.aar) ---
-keep class com.ola.mapsdk.** { *; }
-dontwarn com.ola.mapsdk.**

# --- Ola Maps Navigation SDK (android/app/libs/OlaMapNavigationSDK-*.aar) ---
# Also covers the Places SDK (android/app/libs/Places-sdk-*.jar), which lives
# under the same com.ola.maps package root (com.ola.maps.sdk.*).
-keep class com.ola.maps.** { *; }
-dontwarn com.ola.maps.**

# --- Cashfree Payment Gateway SDK (pulled in via flutter_cashfree_pg_sdk) ---
-keep class com.cashfree.pg.** { *; }
-dontwarn com.cashfree.pg.**
-keep class com.cashfree.flutter_cashfree_pg_sdk.** { *; }
-dontwarn com.cashfree.flutter_cashfree_pg_sdk.**
