/// A content type a model can accept or produce.
///
/// Keep this provider-neutral: adapters translate these values to their own
/// wire formats. Adding audio or video support should not require changing the
/// conversation model or adapter interface.
enum ContentModality {
  text,
  image,
  audio,
  video,
  pdf;

  static ContentModality? tryParse(Object? value) {
    if (value is! String) return null;
    for (final ContentModality modality in values) {
      if (modality.name == value.toLowerCase()) return modality;
    }
    return null;
  }
}
