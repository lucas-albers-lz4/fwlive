(function () {
	'use strict';

	var scene = 'watching';
	var drawer = 'grouped';

	var els = {
		sceneBtns: document.getElementById('scene-btns'),
		drawerBtns: document.getElementById('drawer-btns'),
		pill: document.getElementById('top-pill'),
		dot: document.getElementById('watch-dot'),
		label: document.getElementById('watch-label'),
		count: document.getElementById('watch-count'),
		strip: document.getElementById('watch-strip'),
		pause: document.getElementById('btn-pause'),
		logging: document.getElementById('btn-logging'),
		detail: document.getElementById('btn-detail'),
		fallback: document.getElementById('fallback-badge'),
		drawerEl: document.getElementById('drawer'),
		sumChip: document.getElementById('sum-chip'),
		chips: document.getElementById('chips'),
		empty: document.getElementById('empty'),
		table: document.getElementById('table-wrap'),
		q: document.getElementById('q'),
		proto: document.getElementById('proto'),
		action: document.getElementById('action')
	};

	function setSceneButtons() {
		els.sceneBtns.querySelectorAll('.seg-btn').forEach(function (b) {
			b.classList.toggle('on', b.getAttribute('data-scene') === scene);
		});
	}

	function setDrawerButtons() {
		els.drawerBtns.querySelectorAll('.seg-btn').forEach(function (b) {
			b.classList.toggle('on', b.getAttribute('data-drawer') === drawer);
		});
	}

	function showDrawerPanel() {
		document.querySelectorAll('.drawer-body[data-panel]').forEach(function (p) {
			p.hidden = p.getAttribute('data-panel') !== drawer;
		});
		var isSummary = drawer === 'summary';
		els.sumChip.hidden = !isSummary;
		if (isSummary) {
			els.sumChip.textContent = 'Tint · Tone · Limit 50';
			els.drawerEl.open = false;
		} else {
			els.drawerEl.open = true;
		}
	}

	function applyScene() {
		var paused = scene === 'paused';
		var empty = scene === 'empty';
		var logging = scene === 'logging';
		var filtered = scene === 'filtered';
		var fallback = scene === 'fallback';

		els.strip.classList.toggle('paused', paused);
		els.dot.classList.toggle('on', !paused);
		els.label.textContent = paused ? 'Paused' : 'Watching';
		els.pause.textContent = paused ? 'Resume' : 'Pause';
		els.pill.textContent = paused ? 'PAUSED' : 'LIVE';
		els.pill.style.background = paused ? '#c49100' : '#1f6feb';

		els.fallback.hidden = !fallback;

		if (empty) {
			els.count.textContent = '0 matching · 0/50 stored';
			els.empty.hidden = false;
			els.table.hidden = true;
			els.hint.hidden = true;
		} else {
			els.count.textContent = filtered
				? '2 matching · 3/50 stored'
				: '3 matching · 3/50 stored';
			els.empty.hidden = true;
			els.table.hidden = false;
			els.hint.hidden = false;
		}

		if (logging) {
			els.logging.textContent = 'WAN logging on';
			els.logging.className = 'btn quiet';
			els.logging.title = 'Click to disable WAN logging';
		} else {
			els.logging.textContent = 'Enable logging';
			els.logging.className = 'btn';
			els.logging.title = '';
		}

		els.chips.hidden = !filtered;
		if (filtered) {
			els.q.value = '';
			els.proto.value = 'ICMP';
			els.action.selectedIndex = 1;
		} else {
			els.q.value = '';
			els.proto.value = '';
			els.action.selectedIndex = 0;
		}
	}

	els.sceneBtns.addEventListener('click', function (ev) {
		var btn = ev.target.closest('[data-scene]');
		if (!btn) return;
		scene = btn.getAttribute('data-scene');
		setSceneButtons();
		applyScene();
	});

	els.drawerBtns.addEventListener('click', function (ev) {
		var btn = ev.target.closest('[data-drawer]');
		if (!btn) return;
		drawer = btn.getAttribute('data-drawer');
		setDrawerButtons();
		showDrawerPanel();
	});

	els.hint = document.getElementById('hint');

	setSceneButtons();
	setDrawerButtons();
	showDrawerPanel();
	applyScene();
})();
