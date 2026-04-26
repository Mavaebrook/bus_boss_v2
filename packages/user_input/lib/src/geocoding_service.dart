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
      print('🔍 Searching: $uri');
      final response = await http.get(uri, headers: {
        'User-Agent': 'bus_boss_v2/1.0 (android; test@example.com)',
      });
      print('📡 Status: ${response.statusCode}');
      print('📡 Body preview: ${response.body.substring(0, response.body.length.clamp(0, 200))}');
      if (response.statusCode == 200) {
        final List data = json.decode(response.body);
        print('✅ Parsed ${data.length} results');
        return data
            .map((e) => {
                  'lat': double.parse(e['lat']),
                  'lon': double.parse(e['lon']),
                  'displayName': e['display_name'] ?? '',
                })
            .toList();
      } else {
        return [];
      }
    } catch (e) {
      print('❌ Geocoding error: $e');
      return [];
    }
  }
}
