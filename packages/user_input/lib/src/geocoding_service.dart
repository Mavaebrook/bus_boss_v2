import 'dart:convert';
import 'package:http/http.dart' as http;

class GeocodingService {
  Future<List<Map<String, dynamic>>> search(String query) async {
    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': query,
          'format': 'json',
          'limit': '5',
        },
      );
      final response = await http.get(uri, headers: {
        'User-Agent': 'bus_boss_v2/1.0 (Android; Mavaebrook; github.com/Mavaebrook/bus_boss_v2)',
      });
      if (response.statusCode == 200) {
        final List data = json.decode(response.body);
        return data
            .map((e) => {
                  'lat': double.parse(e['lat']),
                  'lon': double.parse(e['lon']),
                  'displayName': e['display_name'] ?? '',
                })
            .toList();
      } else {
        print('Nominatim error ${response.statusCode}: ${response.body}');
        return [];
      }
    } catch (e) {
      print('Geocoding error: $e');
      return [];
    }
  }
}
