# Updated: 2026-06-15T16:56:48Z
class HourlyAggregator:
    def aggregate(self, events: list) -> dict:
        buckets = {}
        for e in events:
            hour = e['timestamp'][:13]
            buckets.setdefault(hour, []).append(e)
        return buckets

