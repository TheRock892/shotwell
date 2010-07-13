/* Copyright 2009-2010 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

public class EventSourceCollection : ContainerSourceCollection {
    public EventSourceCollection() {
        base(LibraryPhoto.global, Event.BACKLINK_NAME, "EventSourceCollection", get_event_key);
    }
    
    private static int64 get_event_key(DataSource source) {
        Event event = (Event) source;
        EventID event_id = event.get_event_id();
        
        return event_id.id;
    }
    
    public Event? fetch(EventID event_id) {
        return (Event) fetch_by_key(event_id.id);
    }
    
    protected override Gee.Collection<ContainerSource>? get_containers_holding_source(DataSource source) {
        Event? event = ((LibraryPhoto) source).get_event();
        if (event == null)
            return null;
        
        Gee.ArrayList<ContainerSource> list = new Gee.ArrayList<ContainerSource>();
        list.add(event);
        
        return list;
    }
    
    protected override ContainerSource? convert_backlink_to_container(SourceBacklink backlink) {
        EventID event_id = Event.id_from_backlink(backlink);
        
        Event? event = fetch(event_id);
        if (event != null)
            return event;
        
        foreach (ContainerSource container in get_holding_tank()) {
            if (((Event) container).get_event_id().id == event_id.id)
                return container;
        }
        
        return null;
    }
}

public class Event : EventSource, ContainerSource, Proxyable {
    public const string BACKLINK_NAME = "event";
    
    // In 24-hour time.
    public const int EVENT_BOUNDARY_HOUR = 4;
    
    private const time_t TIME_T_DAY = 24 * 60 * 60;
    
    private class EventManager : ViewManager {
        private EventID event_id;

        public EventManager(EventID event_id) {
            this.event_id = event_id;
        }

        public override bool include_in_view(DataSource source) {
            return ((TransformablePhoto) source).get_event_id().id == event_id.id;
        }

        public override DataView create_view(DataSource source) {
            return new PhotoView((PhotoSource) source);
        }
    }
    
    private class EventSnapshot : SourceSnapshot {
        private EventRow row;
        private LibraryPhoto key_photo;
        private Gee.ArrayList<LibraryPhoto> photos = new Gee.ArrayList<LibraryPhoto>();
        
        public EventSnapshot(Event event) {
            // save current state of event
            row = EventTable.get_instance().get_row(event.get_event_id());
            key_photo = event.get_primary_photo();
            
            // stash all the photos in the event ... these are not used when reconstituting the
            // event, but need to know when they're destroyed, as that means the event cannot
            // be restored
            foreach (PhotoSource photo in event.get_photos())
                photos.add((LibraryPhoto) photo);
            
            LibraryPhoto.global.item_destroyed.connect(on_photo_destroyed);
        }
        
        ~EventSnapshot() {
            LibraryPhoto.global.item_destroyed.disconnect(on_photo_destroyed);
        }
        
        public EventRow get_row() {
            return row;
        }
        
        public override void notify_broken() {
            row = EventRow();
            key_photo = null;
            photos.clear();
            
            base.notify_broken();
        }
        
        private void on_photo_destroyed(DataSource source) {
            LibraryPhoto photo = (LibraryPhoto) source;
            
            // if one of the photos in the event goes away, reconstitution is impossible
            if (key_photo != null && key_photo.equals(photo))
                notify_broken();
            else if (photos.contains(photo))
                notify_broken();
        }
    }
    
    private class EventProxy : SourceProxy {
        public EventProxy(Event event) {
            base (event);
        }
        
        public override DataSource reconstitute(int64 object_id, SourceSnapshot snapshot) {
            EventSnapshot event_snapshot = snapshot as EventSnapshot;
            assert(event_snapshot != null);
            
            return Event.reconstitute(object_id, event_snapshot.get_row());
        }
        
    }
    
    public static EventSourceCollection global = null;
    
    private static EventTable event_table = null;
    
    private EventID event_id;
    private string? raw_name;
    private LibraryPhoto primary_photo;
    private ViewCollection view;
    
    private Event(EventID event_id, int64 object_id = INVALID_OBJECT_ID) {
        base (object_id);
        
        this.event_id = event_id;
        this.raw_name = event_table.get_name(event_id);
        
        Gee.ArrayList<PhotoID?> event_photo_ids = PhotoTable.get_instance().get_event_photos(event_id);
        Gee.ArrayList<LibraryPhoto> event_photos = new Gee.ArrayList<LibraryPhoto>();
        foreach (PhotoID photo_id in event_photo_ids)
            event_photos.add(LibraryPhoto.global.fetch(photo_id));
        
        view = new ViewCollection("ViewCollection for Event %lld".printf(event_id.id));
        view.set_comparator(view_comparator);
        view.monitor_source_collection(LibraryPhoto.global, new EventManager(event_id), event_photos); 
        
        // need to do this manually here because only want to monitor ViewCollection contents after
        // initial batch has been added, but need to keep EventSourceCollection apprised
        if (event_photos.size > 0) {
            global.notify_container_contents_added(this, event_photos);
            global.notify_container_contents_altered(this, event_photos, null);
        }
        
        // get the primary photo for monitoring; if not available, use the first photo in the
        // event
        primary_photo = LibraryPhoto.global.fetch(event_table.get_primary_photo(event_id));
        if (primary_photo == null && view.get_count() > 0) {
            primary_photo = (LibraryPhoto) ((DataView) view.get_at(0)).get_source();
            event_table.set_primary_photo(event_id, primary_photo.get_photo_id());
        }
        
        // watch the primary photo to reflect thumbnail changes
        if (primary_photo != null)
            primary_photo.thumbnail_altered.connect(on_primary_thumbnail_altered);

        // watch for for addition, removal, and alteration of photos
        view.items_added.connect(on_photos_added);
        view.items_removed.connect(on_photos_removed);
        view.items_altered.connect(on_photos_altered);
    }

    ~Event() {
        if (primary_photo != null)
            primary_photo.thumbnail_altered.disconnect(on_primary_thumbnail_altered);
        
        view.items_altered.disconnect(on_photos_altered);
        view.items_removed.disconnect(on_photos_removed);
        view.items_added.disconnect(on_photos_added);
    }
    
    public static void init(ProgressMonitor? monitor = null) {
        event_table = EventTable.get_instance();
        global = new EventSourceCollection();
        
        // add all events to the global collection
        Gee.ArrayList<Event> events = new Gee.ArrayList<Event>();
        Gee.ArrayList<Event> unlinked = new Gee.ArrayList<Event>();

        Gee.ArrayList<EventID?> event_ids = event_table.get_events();
        int count = event_ids.size;
        for (int ctr = 0; ctr < count; ctr++) {
            Event event = new Event(event_ids[ctr]);
            
            if (event.get_photo_count() != 0) {
                events.add(event);
                
                continue;
            }
            
            if (event.has_links()) {
                event.rehydrate_backlinks(global, null);
                unlinked.add(event);
                
                continue;
            }
            
            message("Empty event %s with no backlinks found, destroying", event.to_string());
            event.destroy_orphan(true);
        }
        
        global.add_many(events, monitor);
        global.init_add_many_unlinked(unlinked);
    }
    
    public static void terminate() {
    }
    
    private static int64 view_comparator(void *a, void *b) {
        return ((PhotoView *) a)->get_photo_source().get_exposure_time() 
            - ((PhotoView *) b)->get_photo_source().get_exposure_time();
    }
    
    private Gee.ArrayList<LibraryPhoto> views_to_photos(Gee.Iterable<DataObject> views) {
        Gee.ArrayList<LibraryPhoto> photos = new Gee.ArrayList<LibraryPhoto>();
        foreach (DataObject object in views)
            photos.add((LibraryPhoto) ((DataView) object).get_source());
        
        return photos;
    }
    
    private void on_photos_added(Gee.Iterable<DataObject> added) {
        Gee.Collection<LibraryPhoto> photos = views_to_photos(added);
        global.notify_container_contents_added(this, photos);
        global.notify_container_contents_altered(this, photos, null);
        
        notify_altered(new Alteration("contents", "added"));
    }
    
    // Event needs to know whenever a photo is removed from the system to update the event
    private void on_photos_removed(Gee.Iterable<DataObject> removed) {
        Gee.ArrayList<LibraryPhoto> photos = views_to_photos(removed);
        
        global.notify_container_contents_removed(this, photos);
        global.notify_container_contents_altered(this, null, photos);
        
        // update primary photo if it's been removed (and there's one to take its place)
        foreach (LibraryPhoto photo in photos) {
            if (photo == primary_photo) {
                if (get_photo_count() > 0)
                    set_primary_photo((LibraryPhoto) view.get_first().get_source());
                else
                    release_primary_photo();
                
                break;
            }
        }
        
        // evaporate event if no more photos in it; do not touch thereafter
        if (get_photo_count() == 0) {
            global.evaporate(this);
            
            // as it's possible (highly likely, in fact) that all refs to the Event object have
            // gone out of scope now, do NOT touch this, but exit immediately
            return;
        }
        
        notify_altered(new Alteration("contents", "removed"));
    }
    
    public override void notify_relinking(SourceCollection sources) {
        assert(get_photo_count() > 0);
        
        // If the primary photo was lost in the unlink, reestablish it now.
        if (primary_photo == null)
            set_primary_photo((LibraryPhoto) view.get_first().get_source());
        
        base.notify_relinking(sources);
    }
    
    private void on_photos_altered(Gee.Map<DataObject, Alteration> items) {
        foreach (Alteration alteration in items.values) {
            if (alteration.has_subject("metadata")) {
                notify_altered(new Alteration("metadata", "time"));
                
                break;
            }
        }
    }
    
    // This creates an empty event with the key photo.  NOTE: This does not add the key photo to
    // the event.  That must be done manually.
    public static Event create_empty_event(LibraryPhoto key_photo) {
        EventID event_id = EventTable.get_instance().create(key_photo.get_photo_id());
        Event event = new Event(event_id);
        global.add(event);
        
        debug("Created empty event %s", event.to_string());
        
        return event;
    }
    
    // This will create an event using the fields supplied in EventRow.  The event_id is ignored.
    private static Event reconstitute(int64 object_id, EventRow row) {
        EventID event_id = EventTable.get_instance().create_from_row(row);
        Event event = new Event(event_id, object_id);
        global.add(event);
        assert(global.contains(event));
        
        debug("Reconstituted event %s", event.to_string());
        
        return event;
    }
    
    public static EventID id_from_backlink(SourceBacklink backlink) {
        return EventID(backlink.value.to_int64());
    }
    
    public bool has_links() {
        return LibraryPhoto.global.has_backlink(get_backlink());
    }
    
    public SourceBacklink get_backlink() {
        return new SourceBacklink(BACKLINK_NAME, event_id.id.to_string());
    }
    
    public void break_link(DataSource source) {
        ((LibraryPhoto) source).set_event(null);
    }
    
    public void establish_link(DataSource source) {
        ((LibraryPhoto) source).set_event(this);
    }
    
    public bool is_in_starting_day(time_t time) {
        // it's possible the Event ref is held although it's been emptied
        // (such as the user removing items during an import, when events
        // are being generate on-the-fly) ... return false here and let
        // the caller make a new one
        if (view.get_count() == 0)
            return false;
        
        // photos are stored in ViewCollection from earliest to latest
        LibraryPhoto earliest_photo = (LibraryPhoto) ((PhotoView) view.get_at(0)).get_source();
        Time earliest_tm = Time.local(earliest_photo.get_exposure_time());
        
        // use earliest to generate the boundary hour for that day
        Time start_boundary_tm = Time();
        start_boundary_tm.second = 0;
        start_boundary_tm.minute = 0;
        start_boundary_tm.hour = EVENT_BOUNDARY_HOUR;
        start_boundary_tm.day = earliest_tm.day;
        start_boundary_tm.month = earliest_tm.month;
        start_boundary_tm.year = earliest_tm.year;
        start_boundary_tm.isdst = -1;
        
        time_t start_boundary = start_boundary_tm.mktime();
        
        // if the earliest's exposure time was on the day but *before* the boundary hour,
        // step it back a day to the prior day's boundary
        if (earliest_tm.hour < EVENT_BOUNDARY_HOUR)
            start_boundary -= TIME_T_DAY;
        
        time_t end_boundary = (start_boundary + TIME_T_DAY - 1);
        
        return time >= start_boundary && time <= end_boundary;
    }
    
    // This method attempts to add the photo to an event in the supplied list that it would
    // naturally fit into (i.e. its exposure is within the boundary day of the earliest event
    // photo).  Otherwise, a new Event is generated and the photo is added to it and the list.
    public static void generate_import_event(LibraryPhoto photo, ViewCollection events_so_far) {
        time_t exposure_time = photo.get_exposure_time();
        if (exposure_time == 0) {
            debug("Skipping event assignment to %s: no exposure time", photo.to_string());
            
            return;
        }
        
        int count = events_so_far.get_count();
        for (int ctr = 0; ctr < count; ctr++) {
            Event event = (Event) ((EventView) events_so_far.get_at(ctr)).get_source();
            
            if (event.is_in_starting_day(exposure_time)) {
                photo.set_event(event);
                
                return;
            }
        }
        
        // no Event so far fits the bill for this photo, so create a new one
        Event event = new Event(EventTable.get_instance().create(photo.get_photo_id()));
        photo.set_event(event);
        global.add(event);
        
        events_so_far.add(new EventView(event));
    }
    
    public EventID get_event_id() {
        return event_id;
    }
    
    public override SourceSnapshot? save_snapshot() {
        return new EventSnapshot(this);
    }
    
    public SourceProxy get_proxy() {
        return new EventProxy(this);
    }
    
    public override bool equals(DataSource? source) {
        // Validate primary key is unique, which is vital to all this working
        Event? event = source as Event;
        if (event != null) {
            if (this != event) {
                assert(event_id.id != event.event_id.id);
            }
        }
        
        return base.equals(source);
    }
    
    public override string to_string() {
        return "Event [%lld/%lld] %s".printf(event_id.id, get_object_id(), get_name());
    }
    
    public bool has_name() {
        return raw_name != null && raw_name.length > 0;
    }
    
    public override string get_name() {
        if (raw_name != null)
            return raw_name;
        
        // if no name, pretty up the start time
        time_t start_time = get_start_time();
        
        return (start_time != 0) 
            ? format_local_date(Time.local(start_time)) 
            : _("Event %lld").printf(event_id.id);
    }
    
    public string? get_raw_name() {
        return raw_name;
    }
    
    public bool rename(string? name) {
        bool renamed = event_table.rename(event_id, name);
        if (renamed) {
            raw_name = is_string_empty(name) ? null : name;
            notify_altered(new Alteration("metadata", "name"));
        }
        
        return renamed;
    }
    
    public time_t get_creation_time() {
        return event_table.get_time_created(event_id);
    }
    
    public override time_t get_start_time() {
        // Because the ViewCollection is sorted by a DateComparator, the start time is the
        // first item.  However, we keep looking if it has no start time.
        int count = view.get_count();
        for (int i = 0; i < count; i++) {
            time_t time = ((PhotoView) view.get_at(i)).get_photo_source().get_exposure_time();
            if (time != 0)
                return time;
        }

        return 0;
    }
    
    public override time_t get_end_time() {
        int count = view.get_count();
        
        // Because the ViewCollection is sorted by a DateComparator, the end time is the
        // last item--no matter what.
        if (count == 0)
            return 0;
        
        PhotoView photo = (PhotoView) view.get_at(count - 1);
        
        return photo.get_photo_source().get_exposure_time();
    }
    
    public override uint64 get_total_filesize() {
        uint64 total = 0;
        foreach (PhotoSource photo in get_photos()) {
            total += photo.get_filesize();
        }
        
        return total;
    }
    
    public override int get_photo_count() {
        return view.get_count();
    }
    
    public override Gee.Iterable<PhotoSource> get_photos() {
        return (Gee.Iterable<PhotoSource>) view.get_sources();
    }
    
    private void on_primary_thumbnail_altered() {
        notify_thumbnail_altered();
    }

    public LibraryPhoto get_primary_photo() {
        return primary_photo;
    }
    
    public bool set_primary_photo(LibraryPhoto photo) {
        assert(view.has_view_for_source(photo));
        
        bool committed = event_table.set_primary_photo(event_id, photo.get_photo_id());
        if (committed) {
            // switch to the new photo
            if (primary_photo != null)
                primary_photo.thumbnail_altered.disconnect(on_primary_thumbnail_altered);

            primary_photo = photo;
            primary_photo.thumbnail_altered.connect(on_primary_thumbnail_altered);
            
            notify_thumbnail_altered();
        }
        
        return committed;
    }
    
    private void release_primary_photo() {
        if (primary_photo == null)
            return;
        
        primary_photo.thumbnail_altered.disconnect(on_primary_thumbnail_altered);
        primary_photo = null;
    }
    
    public override Gdk.Pixbuf? get_thumbnail(int scale) throws Error {
        return primary_photo != null ? primary_photo.get_thumbnail(scale) : null;
    }
    
    public Gdk.Pixbuf? get_preview_pixbuf(Scaling scaling) {
        try {
            return get_primary_photo().get_preview_pixbuf(scaling);
        } catch (Error err) {
            return null;
        }
    }

    public override void destroy() {
        // stop monitoring the photos collection
        view.halt_monitoring();
        
        // remove from the database
        event_table.remove(event_id);
        
        // mark all photos for this event as now event-less
        PhotoTable.get_instance().drop_event(event_id);
        
        base.destroy();
   }
}

