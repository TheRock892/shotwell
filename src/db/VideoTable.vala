/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

public struct VideoID {
    public const int64 INVALID = -1;

    public int64 id;
    
    public VideoID(int64 id = INVALID) {
        this.id = id;
    }
    
    public bool is_invalid() {
        return (id == INVALID);
    }
    
    public bool is_valid() {
        return (id != INVALID);
    }
    
    public static uint hash(VideoID? a) {
        return int64_hash(a.id);
    }
    
    public static bool equal(void *a, void *b) {
        return ((VideoID *) a)->id == ((VideoID *) b)->id;
    }
    
    public static string upgrade_video_id_to_source_id(VideoID video_id) {
        return ("%s-%016" + int64.FORMAT_MODIFIER + "x").printf(Video.TYPENAME, video_id.id);
    }
}

public class VideoRow {
    public VideoID video_id;
    public string filepath;
    public int64 filesize;
    public time_t timestamp;
    public int width;
    public int height;
    public double clip_duration;
    public bool is_interpretable;
    public time_t exposure_time;
    public ImportID import_id;
    public EventID event_id;
    public string md5;
    public time_t time_created;
    public Rating rating;
    public string title;
    public string? backlinks;
    public time_t time_reimported;
    public uint64 flags;
    public string comment;
}

public class VideoTable : DatabaseTable {
    private static VideoTable instance = null;
    
    private VideoTable() {
        try {
            db.begin();
            db.exec("CREATE TABLE IF NOT EXISTS VideoTable ("
                    + "id INTEGER PRIMARY KEY, "
                    + "filename TEXT UNIQUE NOT NULL, "
                    + "width INTEGER, "
                    + "height INTEGER, "
                    + "clip_duration REAL, "
                    + "is_interpretable INTEGER, "
                    + "filesize INTEGER, "
                    + "timestamp INTEGER, "
                    + "exposure_time INTEGER, "
                    + "import_id INTEGER, "
                    + "event_id INTEGER, "
                    + "md5 TEXT, "
                    + "time_created INTEGER, "
                    + "rating INTEGER DEFAULT 0, "
                    + "title TEXT, "
                    + "backlinks TEXT, "
                    + "time_reimported INTEGER, "
                    + "flags INTEGER DEFAULT 0, "
                    + "comment TEXT "
                    + ")");

            db.exec("CREATE INDEX IF NOT EXISTS VideoEventIDIndex ON VideoTable (event_id)");
            db.commit();
        } catch (Rygel.Database.DatabaseError err) {
            error("VideoTable: %s", err.message);
        }

        set_table_name("VideoTable");
    }
    
    public static VideoTable get_instance() {
        if (instance == null)
            instance = new VideoTable();
        
        return instance;
    }
       
    // VideoRow.video_id, event_id, time_created are ignored on input. All fields are set on exit
    // with values stored in the database.
    public VideoID add(VideoRow video_row) throws Rygel.Database.DatabaseError {
        db.exec(
            "INSERT INTO VideoTable (filename, width, height, clip_duration, is_interpretable, "
            + "filesize, timestamp, exposure_time, import_id, event_id, md5, time_created, title, comment) "
            + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            { (GLib.Value)video_row.filepath,
              (GLib.Value) video_row.width,
              (GLib.Value) video_row.height});
        
        #if 0
        ulong time_created = now_sec();
        
        res = stmt.bind_text(1, video_row.filepath);
        assert(res == Sqlite.OK);
        res = stmt.bind_int(2, video_row.width);
        assert(res == Sqlite.OK);
        res = stmt.bind_int(3, video_row.height);
        assert(res == Sqlite.OK);
        res = stmt.bind_double(4, video_row.clip_duration);
        assert(res == Sqlite.OK);
        res = stmt.bind_int(5, (video_row.is_interpretable) ? 1 : 0);
        assert(res == Sqlite.OK);       
        res = stmt.bind_int64(6, video_row.filesize);
        assert(res == Sqlite.OK);
        res = stmt.bind_int64(7, video_row.timestamp);
        assert(res == Sqlite.OK);
        res = stmt.bind_int64(8, video_row.exposure_time);
        assert(res == Sqlite.OK);
        res = stmt.bind_int64(9, video_row.import_id.id);
        assert(res == Sqlite.OK);
        res = stmt.bind_int64(10, EventID.INVALID);
        assert(res == Sqlite.OK);
        res = stmt.bind_text(11, video_row.md5);
        assert(res == Sqlite.OK);
        res = stmt.bind_int64(12, time_created);
        assert(res == Sqlite.OK);
        res = stmt.bind_text(13, video_row.title);
        assert(res == Sqlite.OK);
        res = stmt.bind_text(14, video_row.comment);
        assert(res == Sqlite.OK);
        
        res = stmt.step();
        if (res != Sqlite.DONE) {
            if (res != Sqlite.CONSTRAINT)
                throw_error("VideoTable.add", res);
        }
        
        // fill in ignored fields with database values
        video_row.video_id = VideoID(db.last_insert_rowid());
        video_row.event_id = EventID();
        video_row.time_created = (time_t) time_created;
        video_row.flags = 0;
       #endif 
        return video_row.video_id;
    }
    
    public bool drop_event(EventID event_id) {
        try {
            db.exec("UPDATE VideoTable SET event_id = ? WHERE event_id = ?",
                    {(GLib.Value) EventID.INVALID, (GLib.Value) event_id.id });

            return true;
        } catch (Rygel.Database.DatabaseError err) {
            error("VideoTable.drop_event: %s", err.message);
        }

        return false;
    }

    private VideoRow? row_from_db (Rygel.Database.Row row) throws Rygel.Database.DatabaseError {
        VideoRow video_row = new VideoRow();
        video_row.video_id.id = row.at<int64> (0);
        video_row.filepath = row.at<string> (1);
        video_row.width = row.at<int> (2);
        video_row.height = row.at<int> (3);
        video_row.clip_duration = row.at<double> (4);
        video_row.is_interpretable = row.at<bool> (5);
        video_row.filesize = row.at<int64> (6);
        video_row.timestamp = (time_t) row.at<int64> (7);
        video_row.exposure_time = (time_t) row.at<int64> (8);
        video_row.import_id.id = row.at<int64> (9);
        video_row.event_id.id = row.at<int64> (10);
        video_row.md5 = row.at<string> (11);
        video_row.time_created = (time_t) row.at<int64> (12);
        video_row.rating = Rating.unserialize(row.at<int> (13));
        video_row.title = row.at<string> (14);
        video_row.backlinks = row.at<string> (15);
        video_row.time_reimported = (time_t) row.at<int64>( 16);
        video_row.flags = row.at<int64> (17);
        video_row.comment = row.at<string> (18);

        return video_row;
    }

    public VideoRow? get_row(VideoID video_id) {
        try {
            var cursor = db.exec_cursor(
            "SELECT id, filename, width, height, clip_duration, is_interpretable, filesize, timestamp, "
            + "exposure_time, import_id, event_id, md5, time_created, rating, title, backlinks, "
            + "time_reimported, flags, comment FROM VideoTable WHERE id=?",
            {(GLib.Value) video_id.id});
            var video_row  = row_from_db (cursor.next());
            video_row.video_id = video_id;

            return video_row;
        } catch (Rygel.Database.DatabaseError err) {
            return null;
        }
    }
    
    public Gee.ArrayList<VideoRow?> get_all() {
        var all = new Gee.ArrayList<VideoRow?>();

        try {
            var cursor = db.exec_cursor(
            "SELECT id, filename, width, height, clip_duration, is_interpretable, filesize, "
            + "timestamp, exposure_time, import_id, event_id, md5, time_created, rating, title, "
            + "backlinks, time_reimported, flags, comment FROM VideoTable");

            foreach (var row in cursor) {
                all.add (row_from_db (row));
            }
        } catch (Rygel.Database.DatabaseError err) {
            GLib.warning ("Error querying database for video rows: %s", err.message);
        }

        return all;
    }
    
    public void set_filepath(VideoID video_id, string filepath) throws DatabaseError {
        update_text_by_id_2(video_id.id, "filename", filepath);
    }
    
    public void set_title(VideoID video_id, string? new_title) throws DatabaseError {
       update_text_by_id_2(video_id.id, "title", new_title != null ? new_title : "");
    }
    
    public void set_comment(VideoID video_id, string? new_comment) throws DatabaseError {
       update_text_by_id_2(video_id.id, "comment", new_comment != null ? new_comment : "");
    }
    
    public void set_exposure_time(VideoID video_id, time_t time) throws DatabaseError {
        update_int64_by_id_2(video_id.id, "exposure_time", (int64) time);
    }

    public void set_rating(VideoID video_id, Rating rating) throws DatabaseError {
        update_int64_by_id_2(video_id.id, "rating", rating.serialize());
    }

    public void set_flags(VideoID video_id, uint64 flags) throws DatabaseError {
        update_int64_by_id_2(video_id.id, "flags", (int64) flags);
    }

    public void update_backlinks(VideoID video_id, string? backlinks) throws DatabaseError {
        update_text_by_id_2(video_id.id, "backlinks", backlinks != null ? backlinks : "");
    }
    
    public void update_is_interpretable(VideoID video_id, bool is_interpretable) throws DatabaseError {
        update_int_by_id_2(video_id.id, "is_interpretable", (is_interpretable) ? 1 : 0);
    }

    public bool set_event(VideoID video_id, EventID event_id) {
        return update_int64_by_id(video_id.id, "event_id", event_id.id);
    }

    public void remove_by_file(File file) throws DatabaseError {
        Sqlite.Statement stmt;
        int res = db.prepare_v2("DELETE FROM VideoTable WHERE filename=?", -1, out stmt);
        assert(res == Sqlite.OK);

        res = stmt.bind_text(1, file.get_path());
        assert(res == Sqlite.OK);
        
        res = stmt.step();
        if (res != Sqlite.DONE)
            throw_error("VideoTable.remove_by_file", res);
    }
    
    public void remove(VideoID videoID) throws DatabaseError {
        Sqlite.Statement stmt;
        int res = db.prepare_v2("DELETE FROM VideoTable WHERE id=?", -1, out stmt);
        assert(res == Sqlite.OK);

        res = stmt.bind_int64(1, videoID.id);
        assert(res == Sqlite.OK);
        
        res = stmt.step();
        if (res != Sqlite.DONE)
            throw_error("VideoTable.remove", res);
    }
    
    public bool is_video_stored(File file) {
        return get_id(file).is_valid();
    }
    
    public VideoID get_id(File file) {
        Sqlite.Statement stmt;
        int res = db.prepare_v2("SELECT ID FROM VideoTable WHERE filename=?", -1, out stmt);
        assert(res == Sqlite.OK);

        res = stmt.bind_text(1, file.get_path());
        assert(res == Sqlite.OK);
        
        res = stmt.step();
        
        return (res == Sqlite.ROW) ? VideoID(stmt.column_int64(0)) : VideoID();
    }

    public Gee.ArrayList<VideoID?> get_videos() throws DatabaseError {
        Sqlite.Statement stmt;
        int res = db.prepare_v2("SELECT id FROM VideoTable", -1, out stmt);
        assert(res == Sqlite.OK);

        Gee.ArrayList<VideoID?> video_ids = new Gee.ArrayList<VideoID?>();
        for (;;) {
            res = stmt.step();
            if (res == Sqlite.DONE) {
                break;
            } else if (res != Sqlite.ROW) {
                throw_error("VideoTable.get_videos", res);
            }
            
            video_ids.add(VideoID(stmt.column_int64(0)));
        }
        
        return video_ids;
    }
    
    private Sqlite.Statement get_duplicate_stmt(File? file, string? md5) {
        assert(file != null || md5 != null);
        
        string sql = "SELECT id FROM VideoTable WHERE";
        bool first = true;
        
        if (file != null) {
            sql += " filename=?";
            first = false;
        }
        
        if (md5 != null) {
            if (!first)
                sql += " OR ";
            
            sql += " md5=?";
        }
        
        Sqlite.Statement stmt;
        int res = db.prepare_v2(sql, -1, out stmt);
        assert(res == Sqlite.OK);
        
        int col = 1;
        
        if (file != null) {
            res = stmt.bind_text(col++, file.get_path());
            assert(res == Sqlite.OK);
        }
               
        if (md5 != null) {
            res = stmt.bind_text(col++, md5);
            assert(res == Sqlite.OK);
        }
        
        return stmt;
    }

    public bool has_duplicate(File? file, string? md5) {
        Sqlite.Statement stmt = get_duplicate_stmt(file, md5);
        int res = stmt.step();
        
        if (res == Sqlite.DONE) {
            // not found
            return false;
        } else if (res == Sqlite.ROW) {
            // at least one found
            return true;
        } else {
            fatal("VideoTable.has_duplicate", res);
        }
        
        return false;
    }
    
    public VideoID[] get_duplicate_ids(File? file, string? md5) {
        Sqlite.Statement stmt = get_duplicate_stmt(file, md5);
        
        VideoID[] ids = new VideoID[0];

        int res = stmt.step();
        while (res == Sqlite.ROW) {
            ids += VideoID(stmt.column_int64(0));
            res = stmt.step();
        }

        return ids;
    }

    public Gee.ArrayList<string> get_event_source_ids(EventID event_id) {
        Sqlite.Statement stmt;
        int res = db.prepare_v2("SELECT id FROM VideoTable WHERE event_id = ?", -1, out stmt);
        assert(res == Sqlite.OK);
        
        res = stmt.bind_int64(1, event_id.id);
        assert(res == Sqlite.OK);
        
        Gee.ArrayList<string> result = new Gee.ArrayList<string>();
        for(;;) {
            res = stmt.step();
            if (res == Sqlite.DONE) {
                break;
            } else if (res != Sqlite.ROW) {
                fatal("get_event_source_ids", res);

                break;
            }
            
            result.add(VideoID.upgrade_video_id_to_source_id(VideoID(stmt.column_int64(0))));
        }
        
        return result;
    }
    
    public void set_timestamp(VideoID video_id, time_t timestamp) throws DatabaseError {
        update_int64_by_id_2(video_id.id, "timestamp", (int64) timestamp);
    }
}

