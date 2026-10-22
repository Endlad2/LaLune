# Патч SettingsPage для FreeTurn

В `Frontend/lib/pages/settings_page.dart` найди `_buildPaperFluxBlock` и добавь рядом `_buildFreeTurnBlock`.

Также добавь в `enum` или `switch`:

```dart
bool get _isFreeTurn => _selectedConfig?.isFreeTurn == true;
```

В `build`:

```
if (!_isPaperFlux && !_isFreeTurn) ...[
  _sectionTitle('Авторизация'),
  _buildAuthBlock(vk),
],
_sectionTitle(_isFreeTurn ? 'Настройки FreeTurn' : (_isPaperFlux ? 'Настройки PaperFlux' : 'Продвинутые настройки')),
if (_isFreeTurn)
  GlassCard(child: _buildFreeTurnBlock())
else if (_isPaperFlux)
  GlassCard(child: _buildPaperFluxBlock())
else
  GlassCard(child: _buildCsqttAdvancedBlock()),
```

`_buildFreeTurnBlock`:

```
Widget _buildFreeTurnBlock() {
  return Column(
    children: [
      InputRow(label: 'Link (Call URL)', controller: _ftLinkCtl),
      _rowDropdown('Transport', _s.ftTransport, ['udp', 'tcp'], (v) { ... }),
      _rowDropdown('Mode', _s.ftMode, ['udp', 'tcp'], (v) { ... }),
      _toggleRow('Bond', _s.ftBond, (v) { ... }),
      _rowDropdown('Obfuscation', _s.ftObf, ['none', 'rtpopus', 'rtpopus2', 'rtpopus3'], (v) { ... }),
      InputRow(label: 'Obf Key', controller: _ftKeyCtl),
      InputRow(label: 'DNS', controller: _ftDnssCtl),
      InputRow(label: 'Client ID', controller: _ftCidCtl),
    ],
  );
}
