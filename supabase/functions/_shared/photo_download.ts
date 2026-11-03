/** Keep the download deadline active through body consumption, not just headers. */
export async function downloadPhotoBytes(url: string, timeoutMs = 20_000): Promise<ArrayBuffer> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) {
      controller.abort();
      throw new Error(`Failed to download image from storage (HTTP ${response.status})`);
    }
    return await response.arrayBuffer();
  } finally {
    clearTimeout(timer);
  }
}
