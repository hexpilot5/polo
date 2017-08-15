/*
 * FileItemCloud.vala
 *
 * Copyright 2017 Tony George <teejeetech@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301, USA.
 *
 *
 */

using GLib;
using Gtk;
using Gee;
using Json;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

public class FileItemCloud : FileItem {
	
	public static string cache_dir;
	
	public string error_msg = "";

	// contructors -------------------------------

	public FileItemCloud.from_path(string _file_path){
		// _file_path can be a local path, or GIO uri
		resolve_file_path(_file_path);
		//query_file_info();
		object_count++;
	}

	public FileItemCloud.from_path_and_type(string _file_path, FileType _file_type) {
		resolve_file_path(_file_path);
		file_type = _file_type;
		//if (query_info){
		//	query_file_info();
		//}
		object_count++;
	}
	
	private void resolve_file_path(string _file_path){

		if (_file_path.contains("://")){
			file_uri = _file_path;
			file = File.new_for_uri(file_uri);
			file_path = file.get_path();
		}
		else {
			file_path = _file_path;
			file = File.new_for_path(file_path);
			file_uri = file.get_uri();
		}

		if (file_path == null){ file_path = ""; }

		file_uri_scheme = file.get_uri_scheme();
		
		//log_debug("");
		//log_debug("file_path      : %s".printf(file_path));
		//log_debug("file.get_path(): %s".printf(file.get_path()));
		//log_debug("file_uri       : %s".printf(file_uri));
		//log_debug("file_uri_scheme: %s".printf(file_uri_scheme));
	}
	
	// properties ------------------------------------------------
	
	public string cached_file_path {
		owned get {
			return path_combine(App.rclone.rclone_cache, thumb_key);
		}
	}
	
	// actions ---------------------------------------------------
	
	public override void query_children(int depth = -1) {

		/* Queries the file item's children using the file_path
		 * depth = -1, recursively find and add all children from disk
		 * depth =  1, find and add direct children
		 * depth =  0, meaningless, should not be used
		 * depth =  X, find and add children upto X levels
		 * */

		if (query_children_aborted) { return; }

		// no need to continue if not a directory
		if (!is_directory) { return; }

		if (depth == 0){ return; } // incorrect method call

		query_children_running = true;
	
		if (depth < 0){
			// we are querying everything under this directory, so the directory size will be accurate; set flag for this
			dir_size_queried = true;
			//log_debug("dir_size_queried: %s".printf(this.file_name));
		}
		
		log_debug("FileItemCloud: query_children(%d): %s".printf(depth, file_path), true);

		save_to_cache();
			
		read_children_from_cache();

		query_children_running = false;
		query_children_pending = false;
	}

	public override void query_children_async() {

		log_debug("FileItemCloud: query_children_async(): %s".printf(file_path));

		query_children_async_is_running = true;
		query_children_aborted = false;

		try {
			//start thread
			Thread.create<void> (query_children_async_thread, true);
		}
		catch (Error e) {
			log_error ("FileItemCloud: query_children_async(): error");
			log_error (e.message);
		}
	}

	private void query_children_async_thread() {
		log_debug("FileItemCloud: query_children_async_thread()");
		query_children(-1); // always add to cache
		query_children_async_is_running = false;
		query_children_aborted = false; // reset
	}
	
	public override FileItem add_child(string item_file_path, FileType item_file_type, int64 item_size, 
		int64 item_size_compressed, bool item_query_file_info){

		// create new item ------------------------------

		//log_debug("add_child: %s ---------------".printf(item_file_path));

		FileItemCloud item = null;

		//item.tag = this.tag;

		// check existing ----------------------------

		bool existing_file = false;

		string item_name = file_basename(item_file_path);
		
		if (children.has_key(item_name) && (children[item_name].file_name == item_name)){

			existing_file = true;
			item = (FileItemCloud) children[item_name];

			//log_debug("existing child, queried: %s".printf(item.fileinfo_queried.to_string()));
		}
		else if (cache.has_key(item_file_path) && (cache[item_file_path].file_path == item_file_path)){
			
			item = (FileItemCloud) cache[item_file_path];

			// set relationships
			item.parent = this;
			this.children[item.file_name] = item;
		}
		else{

			if (item == null){
				item = new FileItemCloud.from_path_and_type(item_file_path, item_file_type);
			}
			
			// set relationships
			item.parent = this;
			this.children[item.file_name] = item;
		}

		item.is_stale = false; // mark fresh

		if (item_file_type == FileType.REGULAR) {

			//log_debug("add_child: regular file");

			// set file sizes
			if (item_size > 0) {
				item._size = item_size;
			}

			// update file counts
			if (!existing_file){

				// update this
				this.file_count++;
				this.file_count_total++;
				if (item.is_backup_or_hidden){
					this.hidden_count++;
				}

				// update parents
				var temp = this;
				while (temp.parent != null) {
					temp.parent.file_count_total++;
					//log_debug("file_count_total += 1, %s".printf(temp.parent.file_count_total));
					temp = (FileItemCloud) temp.parent;
				}

				//log_debug("updated dir counts: %s".printf(item_name));
			}

			if (!existing_file){

				// update this
				this._size += item_size;
				this._size_compressed += item_size_compressed;

				// update parents
				var temp = this;
				while (temp.parent != null) {
					temp.parent._size += item_size;
					temp.parent._size_compressed += item_size_compressed;
					//log_debug("size += %lld, %s".printf(item_size, temp.parent.file_path));
					temp = (FileItemCloud) temp.parent;
				}

				//log_debug("updated dir sizes: %s".printf(item_name));
			}
		}
		else if (item_file_type == FileType.DIRECTORY) {

			//log_debug("add_child: directory");

			if (!existing_file){

				// update this
				this.dir_count++;
				this.dir_count_total++;
				//this.size += _size;
				//size will be updated when children are added

				// update parents
				var temp = this;
				while (temp.parent != null) {
					temp.parent.dir_count_total++;
					//log_debug("dir_count_total += 1, %s".printf(temp.parent.dir_count_total));
					temp = (FileItemCloud) temp.parent;
				}

				//log_debug("updated dir sizes: %s".printf(item_name));
			}
		}

		//log_debug("add_child: finished: fc=%lld dc=%lld path=%s".printf(
		//	file_count, dir_count, item_file_path));

		return item;
	}

	private void save_to_cache(int depth = -1){
		
		log_debug("FileItemCloud: save_to_cache()");
		
		if (file_exists(cached_file_path)){
			var modtime = file_get_modified_date(cached_file_path);
			var now = new GLib.DateTime.now_local();
			if (modtime.add_minutes(10).compare(now) > 0){
				return;
			}
		}
		
		error_msg = "";
		
		string cmd, std_out, std_err;
			
		cmd = "rclone lsjson --max-depth %d '%s'".printf(depth, escape_single_quote(file_path));
		
		log_debug(cmd);
		
		exec_sync(cmd, out std_out, out std_err);
		
		if (std_err.length > 0){
			log_error("std_err:\n%s\n".printf(std_err));
		}

		file_write(cached_file_path, std_out);
		
		if (std_err.length > 0){
			error_msg = std_err;
		}
		
		log_debug("error_msg: %s".printf(error_msg));
		
		log_debug("save_cache: %s".printf(cached_file_path));
	}
	
	public void removed_cached_file(){
		file_delete(cached_file_path);
	}
	
	private void read_children_from_cache(){
		
		//string txt = file_read(cached_file_path);
		
		/*foreach(string line in txt.split("\n")){
			
			
		}*/
		
		// mark existing children as stale -------------------
		
		foreach(var child in children.values){
			child.is_stale = true;
		}
		
		// load children from cached file ------------------------
		
		var f = File.new_for_path(cached_file_path);
		if (!f.query_exists()) {
			return;
		}

		var parser = new Json.Parser();
		try {
			parser.load_from_file(cached_file_path);
		}
		catch (Error e) {
			log_error (e.message);
		}

		var node = parser.get_root();
		var arr = node.get_array();

		foreach(var node_child in arr.get_elements()){
			
			var obj_child = node_child.get_object();
			string path = json_get_string(obj_child, "Path", "");
			string name = json_get_string(obj_child, "Name", "");
			int64 size = json_get_int64(obj_child, "Size", 0);
			string modtime = json_get_string(obj_child, "ModTime", "");
			bool isdir = json_get_bool(obj_child, "IsDir", true);

			string child_name = name;
			string child_path = path_combine(file_path, child_name);
			var child_type = isdir ? FileType.DIRECTORY : FileType.REGULAR;
			var child_modified = parse_date_time(modtime, true);
			
			var child = this.add_child(child_path, child_type, size, 0, false);
			
			child.set_content_type_from_extension();
			child.modified = child_modified;
			child.accessed = child_modified;
			child.changed = child_modified;
			
			if (isdir){
				add_to_cache(child);
			}
		}
		
		// remove stale children ----------------------------
		
		var list = new Gee.ArrayList<string>();
		foreach(var key in children.keys){
			if (children[key].is_stale){
				list.add(key);
			}
		}
		foreach(var key in list){
			//log_debug("unset: key: %s, name: %s".printf(key, children[key].file_name));
			children.unset(key);
		}
	}
	
}
