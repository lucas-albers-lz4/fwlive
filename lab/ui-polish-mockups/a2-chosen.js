(function () {
	'use strict';

	var scene = 'watching';
	var paused = false;

	var els = {
		sceneBtns: document.getElementById('scene-btns'),
		pill: document.getElementById('top-pill'),
		dot: document.getElementById('watch-dot'),
		label: document.getElementById('watch-label'),
		count: document.getElementById('watch-count'),
		strip: document.getElementById('watch-strip'),
		pause: document.getElementById('btn-pause'),
		logging: document.getElementById('btn-logging'),
		fallback: document.getElementById('fallback-badge'),
		chips: document.getElementById('chips'),
		empty: document.getElementById('empty'),
		table: document.getElementById('table-wrap'),
		hint: document.getElementById('hint'),
		q: document.getElementById('q'),
		proto: document.getElementById('proto'),
		action: document.getElementById('action'),
		drawer: document.getElementById('drawer')
	};

	function setSceneButtons() {
		els.sceneBtns.querySelectorAll('.seg-btn').forEach(function (b) {
			b.classList.toggle('on', b.getAttribute('data-scene') === scene);
		});
	}

	function applyPauseUi() {
		els.strip.classList.toggle('paused', paused);
		els.dot.classList.toggle('on', !paused);
		els.label.textContent = paused ? 'Paused' : 'Watching';
		els.pause.textContent = paused ? 'Resume' : 'Pause';
		els.pill.textContent = paused ? 'PAUSED' : 'LIVE';
		els.pill.style.background = paused ? '#c49100' : '#1f6feb';
	}

	function applyScene() {
		paused = scene === 'paused';
		applyPauseUi();

		var empty = scene === 'empty';
		var logging = scene === 'logging';
		var filtered = scene === 'filtered';
		var fallback = scene === 'fallback';

		els.fallback.hidden = !fallback;
		els.drawer.open = false;

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
		} else {
			els.logging.textContent = 'Enable logging';
			els.logging.className = 'btn';
		}

		els.chips.hidden = !filtered;
		els.proto.value = filtered ? 'ICMP' : '';
		els.action.selectedIndex = filtered ? 1 : 0;
		els.q.value = '';
	}

	els.sceneBtns.addEventListener('click', function (ev) {
		var btn = ev.target.closest('[data-scene]');
		if (!btn) return;
		scene = btn.getAttribute('data-scene');
		setSceneButtons();
		applyScene();
	});

	els.pause.addEventListener('click', function () {
		paused = !paused;
		scene = paused ? 'paused' : 'watching';
		setSceneButtons();
		applyPauseUi();
	});

	els.logging.addEventListener('click', function () {
		scene = scene === 'logging' ? 'watching' : 'logging';
		setSceneButtons();
		applyScene();
	});

	var emptyBtn = document.getElementById('btn-empty-logging');
	if (emptyBtn) {
		emptyBtn.addEventListener('click', function () {
			scene = 'logging';
			setSceneButtons();
			applyScene();
		});
	}

	setSceneButtons();
	applyScene();
})();
