/**
 * Browser LuCI E() shim — real DOM, ported from tests/lib/luci-e-harness.js.
 */
(function(global) {
	'use strict';

	const dom = {
		elem(e) {
			return e != null && typeof e === 'object' && 'nodeType' in e;
		},
		parse(s) {
			try {
				const tpl = document.createElement('template');
				tpl.innerHTML = s.trim();
				return tpl.content.firstChild;
			} catch (e) {
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
						node.appendChild(document.createTextNode(String(children[i])));
				}
				return node.lastChild;
			}
			if (typeof children === 'function')
				return this.append(node, children(node));
			if (this.elem(children))
				return node.appendChild(children);
			if (children !== null && children !== undefined) {
				node.innerHTML = String(children);
				return node.lastChild;
			}
			return null;
		},
		attr(node, key, val) {
			if (!this.elem(node))
				return null;
			let attr = null;
			if (typeof key === 'object' && key !== null)
				attr = key;
			else if (typeof key === 'string')
				attr = {}, attr[key] = val;
			for (const k in attr) {
				if (!Object.prototype.hasOwnProperty.call(attr, k) || attr[k] == null)
					continue;
				switch (typeof attr[k]) {
				case 'function':
					node.addEventListener(k, attr[k]);
					break;
				case 'object':
					node.setAttribute(k, JSON.stringify(attr[k]));
					break;
				default:
					node.setAttribute(k, attr[k]);
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
			} else if (this.elem(html)) {
				elem = html;
			} else if (typeof html === 'string' && html.charCodeAt(0) === 60) {
				elem = this.parse(html);
			} else {
				elem = document.createElement(html);
			}
			if (!elem)
				return null;
			this.attr(elem, attr);
			this.append(elem, data);
			return elem;
		}
	};

	global.E = dom.create.bind(dom);
	global.LuciDom = dom;
})(window);
