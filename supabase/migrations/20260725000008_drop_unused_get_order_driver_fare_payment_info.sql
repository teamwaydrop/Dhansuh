-- Migration: Drop get_order_driver_fare_payment_info -- dead code from the retired
-- VPA-based UPI deep-link architecture.
-- Date: 2026-07-25
--
-- This RPC returned the assigned driver's upi_vpa/upi_self_certified/beneficiary_name so the
-- passenger's FarePaymentPanel could build a `upi://pay?pa=<vpa>&...` intent. That intent path was
-- retired (see docs/07_Payments.md section 3 / 1) and no Flutter code calls this RPC anymore --
-- Personal QR payment now reads only the driver's uploaded QR IMAGE (personal_qr_path), rendered
-- entirely on the driver's own screen; the passenger's app never needs the driver's VPA at all.
-- =====================================================================

DROP FUNCTION IF EXISTS public.get_order_driver_fare_payment_info(uuid);
