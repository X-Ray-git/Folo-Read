import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _apiUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelNameController = TextEditingController();
  final _prefetchCountController = TextEditingController();

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiUrlController.text = prefs.getString('llm_api_url') ?? 'https://api.siliconflow.cn/v1/chat/completions';
      _apiKeyController.text = prefs.getString('llm_api_key') ?? '';
      _modelNameController.text = prefs.getString('llm_model_name') ?? 'Pro/MiniMaxAI/MiniMax-M2.5';
      _prefetchCountController.text = (prefs.getInt('llm_prefetch_count') ?? 10).toString();
      _isLoading = false;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('llm_api_url', _apiUrlController.text.trim());
    await prefs.setString('llm_api_key', _apiKeyController.text.trim());
    await prefs.setString('llm_model_name', _modelNameController.text.trim());

    int prefetchCount = int.tryParse(_prefetchCountController.text.trim()) ?? 10;
    await prefs.setInt('llm_prefetch_count', prefetchCount);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Settings saved successfully')),
    );
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
    _apiKeyController.dispose();
    _modelNameController.dispose();
    _prefetchCountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Settings'),
        actions: [
          IconButton(
            icon: Icon(Icons.save),
            onPressed: _saveSettings,
            tooltip: 'Save Settings',
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Translation AI Settings',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: _apiUrlController,
                    decoration: InputDecoration(
                      labelText: 'API URL',
                      border: OutlineInputBorder(),
                      hintText: 'https://api.siliconflow.cn/v1/chat/completions',
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: _apiKeyController,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: _modelNameController,
                    decoration: InputDecoration(
                      labelText: 'Model Name',
                      border: OutlineInputBorder(),
                      hintText: 'Pro/MiniMaxAI/MiniMax-M2.5',
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: _prefetchCountController,
                    decoration: InputDecoration(
                      labelText: 'Prefetch Translation Count',
                      border: OutlineInputBorder(),
                      hintText: '10',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _saveSettings,
                    child: Center(child: Text('Save Settings')),
                  )
                ],
              ),
            ),
    );
  }
}
