/// The first [limit] of [items], comma-separated, with how many more there
/// are — the way a message lists paths without listing thousands.
String sample(Iterable<String> items, [int limit = 3]) {
  final all = items.toList(growable: false);
  final shown = all.take(limit).join(', ');

  return all.length > limit ? '$shown and ${all.length - limit} more' : shown;
}
