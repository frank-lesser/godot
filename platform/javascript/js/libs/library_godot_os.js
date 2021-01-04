/*************************************************************************/
/*  library_godot_os.js                                                  */
/*************************************************************************/
/*                       This file is part of:                           */
/*                           GODOT ENGINE                                */
/*                      https://godotengine.org                          */
/*************************************************************************/
/* Copyright (c) 2007-2021 Juan Linietsky, Ariel Manzur.                 */
/* Copyright (c) 2014-2021 Godot Engine contributors (cf. AUTHORS.md).   */
/*                                                                       */
/* Permission is hereby granted, free of charge, to any person obtaining */
/* a copy of this software and associated documentation files (the       */
/* "Software"), to deal in the Software without restriction, including   */
/* without limitation the rights to use, copy, modify, merge, publish,   */
/* distribute, sublicense, and/or sell copies of the Software, and to    */
/* permit persons to whom the Software is furnished to do so, subject to */
/* the following conditions:                                             */
/*                                                                       */
/* The above copyright notice and this permission notice shall be        */
/* included in all copies or substantial portions of the Software.       */
/*                                                                       */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,       */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF    */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.*/
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY  */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,  */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE     */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                */
/*************************************************************************/

const IDHandler = {
	$IDHandler: {
		_last_id: 0,
		_references: {},

		get: function (p_id) {
			return IDHandler._references[p_id];
		},

		add: function (p_data) {
			const id = ++IDHandler._last_id;
			IDHandler._references[id] = p_data;
			return id;
		},

		remove: function (p_id) {
			delete IDHandler._references[p_id];
		},
	},
};

autoAddDeps(IDHandler, '$IDHandler');
mergeInto(LibraryManager.library, IDHandler);

const GodotConfig = {
	$GodotConfig__postset: 'Module["initConfig"] = GodotConfig.init_config;',
	$GodotConfig__deps: ['$GodotRuntime'],
	$GodotConfig: {
		canvas: null,
		locale: 'en',
		resize_on_start: false,
		on_execute: null,

		init_config: function (p_opts) {
			GodotConfig.resize_on_start = !!p_opts['resizeCanvasOnStart'];
			GodotConfig.canvas = p_opts['canvas'];
			GodotConfig.locale = p_opts['locale'] || GodotConfig.locale;
			GodotConfig.on_execute = p_opts['onExecute'];
			// This is called by emscripten, even if undocumented.
			Module['onExit'] = p_opts['onExit']; // eslint-disable-line no-undef
		},

		locate_file: function (file) {
			return Module['locateFile'](file); // eslint-disable-line no-undef
		},
	},

	godot_js_config_canvas_id_get__sig: 'vii',
	godot_js_config_canvas_id_get: function (p_ptr, p_ptr_max) {
		GodotRuntime.stringToHeap(`#${GodotConfig.canvas.id}`, p_ptr, p_ptr_max);
	},

	godot_js_config_locale_get__sig: 'vii',
	godot_js_config_locale_get: function (p_ptr, p_ptr_max) {
		GodotRuntime.stringToHeap(GodotConfig.locale, p_ptr, p_ptr_max);
	},

	godot_js_config_is_resize_on_start__sig: 'i',
	godot_js_config_is_resize_on_start: function () {
		return GodotConfig.resize_on_start ? 1 : 0;
	},
};

autoAddDeps(GodotConfig, '$GodotConfig');
mergeInto(LibraryManager.library, GodotConfig);

const GodotFS = {
	$GodotFS__deps: ['$FS', '$IDBFS', '$GodotRuntime'],
	$GodotFS__postset: [
		'Module["initFS"] = GodotFS.init;',
		'Module["deinitFS"] = GodotFS.deinit;',
		'Module["copyToFS"] = GodotFS.copy_to_fs;',
	].join(''),
	$GodotFS: {
		_idbfs: false,
		_syncing: false,
		_mount_points: [],

		is_persistent: function () {
			return GodotFS._idbfs ? 1 : 0;
		},

		// Initialize godot file system, setting up persistent paths.
		// Returns a promise that resolves when the FS is ready.
		// We keep track of mount_points, so that we can properly close the IDBFS
		// since emscripten is not doing it by itself. (emscripten GH#12516).
		init: function (persistentPaths) {
			GodotFS._idbfs = false;
			if (!Array.isArray(persistentPaths)) {
				return Promise.reject(new Error('Persistent paths must be an array'));
			}
			if (!persistentPaths.length) {
				return Promise.resolve();
			}
			GodotFS._mount_points = persistentPaths.slice();

			function createRecursive(dir) {
				try {
					FS.stat(dir);
				} catch (e) {
					if (e.errno !== ERRNO_CODES.ENOENT) {
						throw e;
					}
					FS.mkdirTree(dir);
				}
			}

			GodotFS._mount_points.forEach(function (path) {
				createRecursive(path);
				FS.mount(IDBFS, {}, path);
			});
			return new Promise(function (resolve, reject) {
				FS.syncfs(true, function (err) {
					if (err) {
						GodotFS._mount_points = [];
						GodotFS._idbfs = false;
						GodotRuntime.print(`IndexedDB not available: ${err.message}`);
					} else {
						GodotFS._idbfs = true;
					}
					resolve(err);
				});
			});
		},

		// Deinit godot file system, making sure to unmount file systems, and close IDBFS(s).
		deinit: function () {
			GodotFS._mount_points.forEach(function (path) {
				try {
					FS.unmount(path);
				} catch (e) {
					GodotRuntime.print('Already unmounted', e);
				}
				if (GodotFS._idbfs && IDBFS.dbs[path]) {
					IDBFS.dbs[path].close();
					delete IDBFS.dbs[path];
				}
			});
			GodotFS._mount_points = [];
			GodotFS._idbfs = false;
			GodotFS._syncing = false;
		},

		sync: function () {
			if (GodotFS._syncing) {
				GodotRuntime.error('Already syncing!');
				return Promise.resolve();
			}
			GodotFS._syncing = true;
			return new Promise(function (resolve, reject) {
				FS.syncfs(false, function (error) {
					if (error) {
						GodotRuntime.error(`Failed to save IDB file system: ${error.message}`);
					}
					GodotFS._syncing = false;
					resolve(error);
				});
			});
		},

		// Copies a buffer to the internal file system. Creating directories recursively.
		copy_to_fs: function (path, buffer) {
			const idx = path.lastIndexOf('/');
			let dir = '/';
			if (idx > 0) {
				dir = path.slice(0, idx);
			}
			try {
				FS.stat(dir);
			} catch (e) {
				if (e.errno !== ERRNO_CODES.ENOENT) {
					throw e;
				}
				FS.mkdirTree(dir);
			}
			FS.writeFile(path, new Uint8Array(buffer));
		},
	},
};
mergeInto(LibraryManager.library, GodotFS);

const GodotOS = {
	$GodotOS__deps: ['$GodotFS', '$GodotRuntime'],
	$GodotOS__postset: [
		'Module["request_quit"] = function() { GodotOS.request_quit() };',
		'GodotOS._fs_sync_promise = Promise.resolve();',
	].join(''),
	$GodotOS: {
		request_quit: function () {},
		_async_cbs: [],
		_fs_sync_promise: null,

		atexit: function (p_promise_cb) {
			GodotOS._async_cbs.push(p_promise_cb);
		},

		finish_async: function (callback) {
			GodotOS._fs_sync_promise.then(function (err) {
				const promises = [];
				GodotOS._async_cbs.forEach(function (cb) {
					promises.push(new Promise(cb));
				});
				return Promise.all(promises);
			}).then(function () {
				return GodotFS.sync(); // Final FS sync.
			}).then(function (err) {
				// Always deferred.
				setTimeout(function () {
					callback();
				}, 0);
			});
		},
	},

	godot_js_os_finish_async__sig: 'vi',
	godot_js_os_finish_async: function (p_callback) {
		const func = GodotRuntime.get_func(p_callback);
		GodotOS.finish_async(func);
	},

	godot_js_os_request_quit_cb__sig: 'vi',
	godot_js_os_request_quit_cb: function (p_callback) {
		GodotOS.request_quit = GodotRuntime.get_func(p_callback);
	},

	godot_js_os_fs_is_persistent__sig: 'i',
	godot_js_os_fs_is_persistent: function () {
		return GodotFS.is_persistent();
	},

	godot_js_os_fs_sync__sig: 'vi',
	godot_js_os_fs_sync: function (callback) {
		const func = GodotRuntime.get_func(callback);
		GodotOS._fs_sync_promise = GodotFS.sync();
		GodotOS._fs_sync_promise.then(function (err) {
			func();
		});
	},

	godot_js_os_execute__sig: 'ii',
	godot_js_os_execute: function (p_json) {
		const json_args = GodotRuntime.parseString(p_json);
		const args = JSON.parse(json_args);
		if (GodotConfig.on_execute) {
			GodotConfig.on_execute(args);
			return 0;
		}
		return 1;
	},

	godot_js_os_shell_open__sig: 'vi',
	godot_js_os_shell_open: function (p_uri) {
		window.open(GodotRuntime.parseString(p_uri), '_blank');
	},
};

autoAddDeps(GodotOS, '$GodotOS');
mergeInto(LibraryManager.library, GodotOS);
