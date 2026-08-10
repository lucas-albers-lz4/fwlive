'use strict';

/**
 * LuCI-accurate E() DOM harness for Node tests (fwlive wave #149).
 *
 * Ported from openwrt/luci@f699752316ac4651ae4f4f966510d352670ca87a —
 * dom.append/dom.create (plus the elem/attr/parse helpers they call),
 * modules/luci-base/htdocs/luci-static/resources/luci.js.
 *
 * Unlike the module-loader stub `fakeE` (tests/lib/load-fwlive-module.js),
 * which returns { tag, attrs, children } object literals, this harness
 * renders real Node objects so the production array-vs-bare-string child
 * discrimination is observable:
 *
 *   - array child            → document.createTextNode() → appendChild (NO innerHTML write)
 *   - bare string child      → node.innerHTML = value    (the HTML sink; records every write)
 *   - DOM Node child         → node.appendChild()
 *
 * `E` is `dom.create` bound to the ported `dom` object, exactly like LuCI's
 * view-loader binding.
 */

/* Minimal Node surface: a recording innerHTML SETTER (every write pushed to
 * _innerHTMLWrites), appendChild, setAttribute, plus the nodeType / lastChild
 * / addEventListener members the ported dom code depends on. */
class Node {
	constructor(nodeType) {
		this.nodeType = nodeType;
		this.childNodes = [];
		this.lastChild = null;
		this._innerHTML = '';
		this._innerHTMLWrites = [];
		this._attrs = {};
		this._listeners = {};
	}

	get innerHTML() {
		return this._innerHTML;
	}

	set innerHTML(value) {
		const html = String(value);
		this._innerHTMLWrites.push(html);
		this._innerHTML = html;
		this.childNodes = [];
		this.lastChild = null;
	}

	appendChild(node) {
		this.childNodes.push(node);
		this.lastChild = node;
		return node;
	}

	setAttribute(key, value) {
		this._attrs[key] = String(value);
	}

	addEventListener(type, fn) {
		(this._listeners[type] = this._listeners[type] || []).push(fn);
	}
}

class Element extends Node {
	constructor(tagName) {
		super(1);
		this.tagName = tagName;
	}
}

class TextNode extends Node {
	constructor(text) {
		super(3);
		this.textContent = String(text);
		this.nodeValue = this.textContent;
	}
}

class DocumentFragment extends Node {
	constructor() {
		super(11);
	}
}

/* Node has no DOMParser; the ported parse() swallows the failure and returns
 * null, which is the same result create() gets for a "<"-prefixed name here. */
const domParser = null;

const document = {
	createElement: function(tagName) { return new Element(tagName); },
	createTextNode: function(text) { return new TextNode(text); },
	createDocumentFragment: function() { return new DocumentFragment(); }
};

/* --- Ported verbatim from upstream luci.js (openwrt/luci@f6997523) --- */

const dom = {
	elem(e) {
		return (e != null && typeof(e) == 'object' && 'nodeType' in e);
	},

	parse(s) {
		try {
			return domParser.parseFromString(s, 'text/html').body.firstChild;
		}
		catch(e) {
			return null;
		}
	},

	append(node, children) {
		if (!this.elem(node))
			return null;

		if (Array.isArray(children)) {
			for (let i = 0; i < children.length; i++) {
				if (this.elem(children[i]))
					node.appendChild(children[i]);
				else if (children[i] !== null && children[i] !== undefined)
					node.appendChild(document.createTextNode(`${children[i]}`));
			}

			return node.lastChild;
		}
		else if (typeof(children) === 'function') {
			return this.append(node, children(node));
		}
		else if (this.elem(children)) {
			return node.appendChild(children);
		}
		else if (children !== null && children !== undefined) {
			node.innerHTML = `${children}`;
			return node.lastChild;
		}

		return null;
	},

	attr(node, key, val) {
		if (!this.elem(node))
			return null;

		let attr = null;

		if (typeof(key) === 'object' && key !== null)
			attr = key;
		else if (typeof(key) === 'string')
			attr = {}, attr[key] = val;

		for (key in attr) {
			if (!attr.hasOwnProperty(key) || attr[key] == null)
				continue;

			switch (typeof(attr[key])) {
			case 'function':
				node.addEventListener(key, attr[key]);
				break;

			case 'object':
				node.setAttribute(key, JSON.stringify(attr[key]));
				break;

			default:
				node.setAttribute(key, attr[key]);
			}
		}
	},

	create() {
		const html = arguments[0];
		let attr = arguments[1];
		let data = arguments[2];
		let elem;

		if (!(attr instanceof Object) || Array.isArray(attr))
			data = attr, attr = null;

		if (Array.isArray(html)) {
			elem = document.createDocumentFragment();
			for (let i = 0; i < html.length; i++)
				elem.appendChild(this.create(html[i]));
		}
		else if (this.elem(html)) {
			elem = html;
		}
		else if (typeof(html) === 'string' && html.charCodeAt(0) === 60) {
			elem = this.parse(html);
		}
		else {
			elem = document.createElement(html);
		}

		if (!elem)
			return null;

		this.attr(elem, attr);
		this.append(elem, data);

		return elem;
	}
};

/* LuCI binds E → dom.create in the view context. */
const E = dom.create.bind(dom);

module.exports = {
	Node: Node,
	Element: Element,
	TextNode: TextNode,
	DocumentFragment: DocumentFragment,
	document: document,
	dom: dom,
	E: E,
	PortedFrom: 'openwrt/luci@f699752316ac4651ae4f4f966510d352670ca87a'
};
