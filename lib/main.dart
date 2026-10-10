import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// API: Cat Facts  https://catfact.ninja 
//   Screen 1 -> GET /facts?limit=20   (a list, fetched once)
//   Screen 2 -> GET /fact             (a RANDOM fact every call, so it changes)
// ---------------------------------------------------------------------------

void main() => runApp(const MyApp());

// ============================ MODEL =========================================

class CatFact {
  final String fact;
  final int length;

  const CatFact({required this.fact, required this.length});

  factory CatFact.fromJson(Map<String, dynamic> json) {
    return CatFact(
      fact: json['fact'] as String? ?? '',
      length: json['length'] as int? ?? 0,
    );
  }
}

// ============================ API SERVICE ===================================

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class CatApi {
  static const _base = 'https://catfact.ninja';
  static const _timeout = Duration(seconds: 8);

  /// One place for: timeout + status code check + error translation.
  static Future<Map<String, dynamic>> _get(String path) async {
    try {
      final response =
          await http.get(Uri.parse('$_base$path')).timeout(_timeout);

      if (response.statusCode != 200) {
        throw ApiException('Server error (code ${response.statusCode})');
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException('The request timed out. Check your connection.');
    } on http.ClientException {
      // Airplane mode / no internet ends up here.
      throw ApiException('No internet connection.');
    } on FormatException {
      throw ApiException('Got a bad response from the server.');
    } catch (_) {
      throw ApiException('Something went wrong. Please try again.');
    }
  }

  /// Screen 1: a list of facts, fetched once.
  static Future<List<CatFact>> fetchFacts() async {
    final json = await _get('/facts?limit=20');
    final list = json['data'] as List<dynamic>? ?? [];
    return list
        .map((item) => CatFact.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Screen 2: one random fact (different almost every call).
  static Future<CatFact> fetchRandomFact() async {
    final json = await _get('/fact');
    return CatFact.fromJson(json);
  }

  /// A stream that never dies: errors are wrapped in a BeltEvent instead of
  /// being thrown, so one failed fetch just shows an error and the next tick
  /// tries again. It stops automatically when the screen stops listening.
  static Stream<BeltEvent> beltStream() async* {
    while (true) {
      try {
        yield BeltEvent.success(await fetchRandomFact());
      } catch (e) {
        yield BeltEvent.failure(e.toString());
      }
      await Future.delayed(const Duration(seconds: 5));
    }
  }
}

class BeltEvent {
  final CatFact? fact;
  final String? error;
  final DateTime time = DateTime.now();

  BeltEvent.success(this.fact) : error = null;
  BeltEvent.failure(this.error) : fact = null;
}

// ============================ APP ===========================================

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cat Facts',
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_index == 0 ? 'The Order' : 'The Belt')),
      body: IndexedStack(
        index: _index,
        children: const [OrderScreen(), BeltScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.list), label: 'The Order'),
          NavigationDestination(icon: Icon(Icons.stream), label: 'The Belt'),
        ],
      ),
    );
  }
}

// ============================ SCREEN 1: FUTURE ==============================

class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key});

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  // Stored in State so build() re-running does NOT refetch.
  late Future<List<CatFact>> _future;

  @override
  void initState() {
    super.initState();
    _future = CatApi.fetchFacts();
  }

  void _retry() {
    setState(() {
      _future = CatApi.fetchFacts();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<CatFact>>(
      future: _future,
      builder: (context, snapshot) {
        // 1. Loading
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        // 2. Error + Retry
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 12),
                  Text(snapshot.error.toString(), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }

        // 3. Empty
        final facts = snapshot.data ?? [];
        if (facts.isEmpty) {
          return const Center(child: Text('No facts to show yet.'));
        }

        // 4. Real data
        return ListView.separated(
          itemCount: facts.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => ListTile(
            leading: CircleAvatar(child: Text('${i + 1}')),
            title: Text(facts[i].fact),
            subtitle: Text('${facts[i].length} characters'),
          ),
        );
      },
    );
  }
}

// ============================ SCREEN 2: STREAM ==============================

class BeltScreen extends StatefulWidget {
  const BeltScreen({super.key});

  @override
  State<BeltScreen> createState() => _BeltScreenState();
}

class _BeltScreenState extends State<BeltScreen> {
  // Created ONCE (not inside build) so the stream isn't restarted on rebuild.
  late final Stream<BeltEvent> _stream = CatApi.beltStream();

  CatFact? _lastGoodFact; // keep showing the last fact if a later fetch fails
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BeltEvent>(
      stream: _stream,
      builder: (context, snapshot) {
        // 1. Loading before first data
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        // Safety net (our stream wraps errors, but just in case)
        if (snapshot.hasError) {
          return Center(child: Text('Stream error: ${snapshot.error}'));
        }

        final event = snapshot.data!;
        final failed = event.error != null;

        if (!failed) {
          _lastGoodFact = event.fact;
          _count++;
        }

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 2. Error state (stream keeps running and retries by itself)
              if (failed)
                Card(
                  color: Colors.red.shade50,
                  child: ListTile(
                    leading: const Icon(Icons.wifi_off, color: Colors.red),
                    title: Text(event.error!),
                    subtitle: const Text('Trying again in 5 seconds...'),
                  ),
                ),
              const SizedBox(height: 16),
              if (_lastGoodFact == null)
                const Text('Waiting for the first fact...')
              else
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: Card(
                    key: ValueKey(_lastGoodFact!.fact),
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        _lastGoodFact!.fact,
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Text('Facts received: $_count  •  updates every 5s'),
            ],
          ),
        );
      },
    );
  }
}
