'use strict';
'require view';
'require rpc';
'require ui';

/*
 * luci-app-oxidns-plus - single page for warming, DHCP hostnames, diagnostics.
 * All privileged work goes through the luci.oxidnsplus rpcd backend.
 */

var FIELDS = [
	'warm_enabled', 'warm_interval', 'warm_types', 'warm_list',
	'warm_on_boot', 'warm_wait_ready', 'resolver', 'resolver_port',
	'dig_timeout', 'dig_tries', 'sleep_between',
	'dhcp_enabled', 'dhcp_interval', 'lease_file', 'lease_domain',
	'hosts_output', 'dhcp_auto_reload', 'reload_mode',
	'config_path', 'working_dir'
];

var BOOL_FIELDS = [
	'warm_enabled', 'warm_on_boot', 'dhcp_enabled', 'dhcp_auto_reload'
];

var callStatus = rpc.declare({
	object: 'luci.oxidnsplus', method: 'status', expect: {}
});

var callSettingsRead = rpc.declare({
	object: 'luci.oxidnsplus', method: 'settings_read', expect: {}
});

var callSettingsSave = rpc.declare({
	object: 'luci.oxidnsplus', method: 'settings_save',
	params: FIELDS, expect: {}
});

var callWarmNow = rpc.declare({
	object: 'luci.oxidnsplus', method: 'warm_now', expect: {}
});

var callWarmListRead = rpc.declare({
	object: 'luci.oxidnsplus', method: 'warm_list_read', expect: {}
});

var callWarmListSave = rpc.declare({
	object: 'luci.oxidnsplus', method: 'warm_list_save',
	params: [ 'content' ], expect: {}
});

var callDhcpNow = rpc.declare({
	object: 'luci.oxidnsplus', method: 'dhcp_now',
	params: [ 'reload' ], expect: {}
});

var callDiagnose = rpc.declare({
	object: 'luci.oxidnsplus', method: 'diagnose', expect: {}
});

var callQueryTest = rpc.declare({
	object: 'luci.oxidnsplus', method: 'query_test',
	params: [ 'name', 'type' ], expect: {}
});

var callRecommendedConfig = rpc.declare({
	object: 'luci.oxidnsplus', method: 'recommended_config', expect: {}
});

var callApplyTuning = rpc.declare({
	object: 'luci.oxidnsplus', method: 'apply_config_tuning',
	params: [ 'confirm', 'reload' ], expect: {}
});

function el(id) {
	return document.getElementById(id);
}

function fieldValue(id) {
	var node = el(id);
	return node ? node.value : '';
}

function checked(id) {
	var node = el(id);
	return !!(node && node.checked);
}

function row(label, input, hint) {
	var children = [ input ];
	if (hint) {
		children.push(E('div', { 'class': 'cbi-value-description' }, hint));
	}
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 260px' }, label),
		E('div', { 'class': 'td left' }, E('div', {}, children))
	]);
}

function textInput(id, value, placeholder) {
	return E('input', {
		'id': id,
		'class': 'cbi-input-text',
		'type': 'text',
		'value': value || '',
		'placeholder': placeholder || null
	});
}

function checkInput(id, value) {
	return E('input', {
		'id': id,
		'type': 'checkbox',
		'checked': (value === '1' || value === 1 || value === true) ? 'checked' : null
	});
}

function selectInput(id, options, value) {
	var nodes = [];
	for (var i = 0; i < options.length; i++) {
		nodes.push(E('option', {
			'value': options[i][0],
			'selected': options[i][0] === value ? 'selected' : null
		}, options[i][1]));
	}
	return E('select', { 'id': id, 'class': 'cbi-input-select' }, nodes);
}

function setStatus(message, danger) {
	var node = el('oxidnsplus-status');
	if (!node) return;
	node.textContent = message || '';
	node.className = danger ? 'alert-message error' : 'alert-message info';
}

function setOutput(text) {
	var node = el('oxidnsplus-output');
	if (node) node.textContent = text || '';
}

function runAction(promise, label) {
	ui.showModal(_('OxiDNS Plus'), [ E('p', {}, _('Working...')) ]);
	return L.resolveDefault(promise, null).then(function(res) {
		ui.hideModal();
		if (!res) {
			setOutput(label + ': no response from rpcd');
			setStatus(label + ': no response from rpcd', true);
			return;
		}
		if (res.output !== undefined) {
			setOutput(res.output || '(no output)');
		} else if (res.content !== undefined) {
			setOutput(res.content || '(empty)');
		} else if (res.ok === false) {
			setOutput(JSON.stringify(res, null, 2));
		} else {
			setOutput(res.message || label + ': ok');
		}
		if (res.ok === false) {
			setStatus((res.message || res.code || label + ' failed'), true);
		} else {
			setStatus(_('Done.'), false);
		}
	}).catch(function(err) {
		ui.hideModal();
		setStatus(err.message || String(err), true);
	});
}

function settingId(name) {
	return 'oxidnsplus-' + name;
}

function readForm() {
	var payload = {};
	for (var i = 0; i < FIELDS.length; i++) {
		var name = FIELDS[i];
		var id = settingId(name);
		if (BOOL_FIELDS.indexOf(name) !== -1) {
			payload[name] = checked(id) ? '1' : '0';
		} else {
			payload[name] = fieldValue(id);
		}
	}
	return payload;
}

function saveSettings() {
	var payload = readForm();
	var args = FIELDS.map(function(name) { return payload[name]; });
	return runAction(callSettingsSave.apply(null, args), 'settings');
}

function saveWarmList() {
	return runAction(callWarmListSave(fieldValue('oxidnsplus-warm-list-content')), 'warm list');
}

function statusRow(label, value, good) {
	var text = value ? _('Yes') : _('No');
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 260px' }, label),
		E('div', { 'class': 'td left' }, [
			E('span', { 'style': good ? 'color:#2e7d32' : 'color:#c62828' }, text)
		])
	]);
}

function configRow(label, value) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 260px' }, label),
		E('div', { 'class': 'td left' }, String(value === undefined ? '-' : value))
	]);
}

function section(title, rows) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, title),
		E('div', { 'class': 'table cbi-section-table' }, rows)
	]);
}

function actionButton(label, handler, positive) {
	return E('button', {
		'class': 'btn cbi-button ' + (positive ? 'cbi-button-positive' : 'cbi-button'),
		'click': function(ev) { ev.preventDefault(); return handler(); }
	}, label);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callSettingsRead(), {}),
			L.resolveDefault(callStatus(), {}),
			L.resolveDefault(callWarmListRead(), {})
		]);
	},

	render: function(data) {
		var s = data[0] || {};
		var st = data[1] || {};
		var list = data[2] || {};
		var svc = st.service || {};
		var cfg = st.config || {};
		var warmState = st.warm || {};
		var dhcpState = st.dhcp || {};

		function setting(name, fallback) {
			return s[name] === undefined ? (fallback || '') : s[name];
		}

		var statusRows = [
			statusRow(_('Service enabled'), svc.enabled, !!svc.enabled),
			statusRow(_('Cron block installed'), svc.cron_installed, !!svc.cron_installed),
			statusRow(_('OxiDNS core running'), svc.core_running, !!svc.core_running),
			statusRow(_('Helper scripts executable'), svc.scripts_ok, !!svc.scripts_ok),
			configRow(_('Last warming'), (warmState.last_run || '-') + '  (' +
				(warmState.domains || '0') + ' domains, ' +
				(warmState.queries_ok || '0') + ' ok / ' +
				(warmState.queries_failed || '0') + ' failed)'),
			configRow(_('Last DHCP sync'), (dhcpState.last_run || '-') + '  (' +
				(dhcpState.leases || '0') + ' leases, reload=' +
				(dhcpState.reload || '-') + ')'),
			configRow(_('lazy_cache_ttl'), cfg.lazy_cache_ttl),
			configRow(_('ECS handling'), cfg.ecs === 'stripped' ? 'stripped (recommended)' : cfg.ecs),
			configRow(_('dhcp-hosts referenced'), cfg.dhcp_hosts_referenced ? _('Yes') : _('No')),
			configRow(_('guest branch'), cfg.guest_detected ? 'detected' : 'none')
		];

		var warmRows = [
			row(_('Enable warming'), checkInput(settingId('warm_enabled'), setting('warm_enabled', '1'))),
			row(_('Interval (minutes)'), textInput(settingId('warm_interval'), setting('warm_interval', '2'))),
			row(_('Record types'), selectInput(settingId('warm_types'), [
				[ 'A AAAA', 'A + AAAA' ], [ 'A', 'A only' ], [ 'AAAA', 'AAAA only' ]
			], setting('warm_types', 'A AAAA'))),
			row(_('Run once at boot'), checkInput(settingId('warm_on_boot'), setting('warm_on_boot', '1'))),
			row(_('Wait for core (seconds)'), textInput(settingId('warm_wait_ready'), setting('warm_wait_ready', '15'))),
			row(_('Warm list path'), textInput(settingId('warm_list'), setting('warm_list', '/etc/oxidns/warm.list'))),
			row(_('Local resolver'), textInput(settingId('resolver'), setting('resolver', '127.0.0.1'))),
			row(_('Resolver port'), textInput(settingId('resolver_port'), setting('resolver_port', '5333'))),
			row('dig timeout / tries (s)', textInput(settingId('dig_timeout'), setting('dig_timeout', '1'))),
			row('dig tries', textInput(settingId('dig_tries'), setting('dig_tries', '1'))),
			row('Sleep between queries (s)', textInput(settingId('sleep_between'), setting('sleep_between', '0')))
		];

		var dhcpRows = [
			row(_('Enable DHCP sync'), checkInput(settingId('dhcp_enabled'), setting('dhcp_enabled', '0')),
				_('Reload OxiDNS after DHCP sync')),
			row(_('DHCP interval (minutes)'), textInput(settingId('dhcp_interval'), setting('dhcp_interval', '10'))),
			row(_('Lease file'), textInput(settingId('lease_file'), setting('lease_file', '/tmp/dhcp.leases'))),
			row(_('Local domain suffix'), textInput(settingId('lease_domain'), setting('lease_domain', 'lan'))),
			row(_('Hosts output'), textInput(settingId('hosts_output'), setting('hosts_output', '/etc/oxidns/dhcp-hosts'))),
			row(_('Auto reload on change'), checkInput(settingId('dhcp_auto_reload'), setting('dhcp_auto_reload', '0'))),
			row(_('Reload mode'), selectInput(settingId('reload_mode'), [
				[ 'signal', 'signal (gentle)' ], [ 'restart', 'restart (always effective)' ]
			], setting('reload_mode', 'signal')))
		];

		var advancedRows = [
			row(_('Config path'), textInput(settingId('config_path'), setting('config_path', '/etc/oxidns/config.yaml'))),
			row(_('Working directory'), textInput(settingId('working_dir'), setting('working_dir', '/var/lib/oxidns')))
		];

		var actions = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Actions')),
			E('div', { 'class': 'cbi-button-row' }, [
				actionButton(_('Warm now'), function() { return runAction(callWarmNow(), 'warm'); }, true),
				actionButton(_('Sync DHCP now'), function() {
					return runAction(callDhcpNow(checked('oxidnsplus-dhcp-reload')), 'dhcp');
				}),
				E('input', { 'id': 'oxidnsplus-dhcp-reload', 'type': 'checkbox', 'style': 'margin:0 .4em 0 1em' }),
				E('span', {}, 'reload'),
				actionButton(_('Run diagnostics'), function() { return runAction(callDiagnose(), 'diagnose'); }),
				actionButton(_('Recommended config'), function() {
					return runAction(callRecommendedConfig(), 'recommended config');
				}),
				actionButton(_('Config tuning'), function() {
					if (!window.confirm(_('Confirm config tuning') + '\n\n' +
							_('This changes only lazy_cache_ttl in the existing config and validates with oxidns check. Continue?'))) {
						return Promise.resolve();
					}
					return runAction(callApplyTuning(1, 1), 'config tuning');
				}, true)
			]),
			E('div', { 'style': 'margin-top:.8em' }, [
				E('input', {
					'id': 'oxidnsplus-query-name',
					'class': 'cbi-input-text',
					'placeholder': 'www.google.com',
					'value': 'www.google.com'
				}),
				selectInput('oxidnsplus-query-type', [
					[ 'A', 'A' ], [ 'AAAA', 'AAAA' ]
				], 'A'),
				actionButton(_('Query test'), function() {
					return runAction(callQueryTest(
						fieldValue('oxidnsplus-query-name') || 'www.google.com',
						fieldValue('oxidnsplus-query-type') || 'A'), 'query test');
				})
			]),
			E('div', { 'id': 'oxidnsplus-status', 'style': 'margin-top:1em' }),
			E('pre', {
				'id': 'oxidnsplus-output',
				'style': 'margin-top:.6em; padding:.8em; background:#f5f5f5; color:#222; ' +
					'white-space:pre-wrap; max-height:420px; overflow:auto; font-size:12px'
			}, _('Output'))
		]);

		var warmListSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Warm list')),
			E('div', { 'class': 'cbi-value-description' },
				_('One domain per line. Blank lines and #comments are ignored.')),
			E('textarea', {
				'id': 'oxidnsplus-warm-list-content',
				'class': 'cbi-input-textarea',
				'rows': '18',
				'style': 'width:100%; font-family:monospace; font-size:12px; margin-top:.6em'
			}, list.content || ''),
			E('div', { 'class': 'cbi-button-row', 'style': 'margin-top:.6em' }, [
				actionButton(_('Save Warm List'), function() { return saveWarmList(); }, true)
			])
		]);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('OxiDNS Plus')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Cache warming, DHCP hostnames, upstream diagnostics and guarded config tuning for an existing OxiDNS runtime.')),
			section(_('Runtime status'), statusRows),
			section(_('Cache warming'), warmRows),
			section(_('DHCP hostnames'), dhcpRows),
			section(_('Advanced paths'), advancedRows),
			E('div', { 'class': 'cbi-button-row' }, [
				actionButton(_('Save Settings'), function() { return saveSettings(); }, true)
			]),
			actions,
			warmListSection
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
