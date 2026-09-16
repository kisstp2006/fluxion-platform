// SPDX-License-Identifier: BSL-1.0
//
// The one piece of Java fluxion-platform has: a NativeActivity that hears the
// answer to an activity it started. NativeActivity never hands
// onActivityResult to native code, and the system's document picker answers
// nowhere else. An app names this class in its manifest where it would name
// android.app.NativeActivity, and packs `zig build android-dex`'s classes.dex
// into its APK - see the README.

package dev.fluxion.platform;

import android.app.NativeActivity;
import android.content.ClipData;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.view.View;
import android.view.WindowInsets;
import android.webkit.MimeTypeMap;
import java.util.ArrayList;

public class FluxionActivity extends NativeActivity {
    /** Registered by the native library as the activity starts. */
    private static native void answered(int id, String[] names, String[] uris);

    /** The edges the system draws over - a notch, the gesture bar - in pixels. */
    private static native void insetsChanged(int left, int top, int right, int bottom);

    private static final int PICK = 0x464c;
    private int pendingId;
    private boolean pendingFolder;

    /**
     * The insets are heard here rather than asked for: they arrive at the first
     * layout and again whenever the phone is turned or the bars come and go,
     * and a program that polled would miss the change it needs to lay out for.
     *
     * `super.onCreate` is what loads the native library and registers
     * `insetsChanged`, so the listener below can only ever fire after it.
     */
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        View view = getWindow().getDecorView();
        view.setOnApplyWindowInsetsListener((v, windowInsets) -> {
            report(windowInsets);
            return v.onApplyWindowInsets(windowInsets);
        });
    }

    private static void report(WindowInsets windowInsets) {
        int left;
        int top;
        int right;
        int bottom;
        if (Build.VERSION.SDK_INT >= 30) {
            Insets bars = windowInsets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            left = bars.left;
            top = bars.top;
            right = bars.right;
            bottom = bars.bottom;
        } else {
            // The old pair, which is the system bars and the cutout together.
            left = windowInsets.getSystemWindowInsetLeft();
            top = windowInsets.getSystemWindowInsetTop();
            right = windowInsets.getSystemWindowInsetRight();
            bottom = windowInsets.getSystemWindowInsetBottom();
        }
        try {
            insetsChanged(left, top, right, bottom);
        } catch (UnsatisfiedLinkError e) {
            // A build whose native library did not register it: no insets, and
            // no reason to take the activity down over it.
        }
    }

    /** Open the document picker. Called on the program's thread; started on the UI one. */
    public void openDocuments(int id, boolean folder, boolean multiple, String[] extensions) {
        runOnUiThread(() -> start(id, folder, multiple, extensions));
    }

    private void start(int id, boolean folder, boolean multiple, String[] extensions) {
        Intent intent;
        if (folder) {
            intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        } else {
            intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType("*/*");
            String[] types = mimeTypes(extensions);
            if (types != null) intent.putExtra(Intent.EXTRA_MIME_TYPES, types);
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple);
        }
        pendingId = id;
        pendingFolder = folder;
        try {
            startActivityForResult(intent, PICK);
        } catch (RuntimeException e) {
            deliver(id, new ArrayList<>(), new ArrayList<>());
        }
    }

    /** The types of the extensions, or null - every file - if one has none Android knows. */
    private static String[] mimeTypes(String[] extensions) {
        if (extensions.length == 0) return null;
        MimeTypeMap map = MimeTypeMap.getSingleton();
        ArrayList<String> types = new ArrayList<>();
        for (String extension : extensions) {
            String type = extension.equals("*") ? null : map.getMimeTypeFromExtension(extension.toLowerCase());
            if (type == null) return null;
            if (!types.contains(type)) types.add(type);
        }
        return types.toArray(new String[0]);
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        if (request != PICK) {
            super.onActivityResult(request, result, data);
            return;
        }
        int id = pendingId;
        boolean folder = pendingFolder;
        Intent chosen = result == RESULT_OK ? data : null;
        // A provider may be slow to name its documents, and this is the UI thread.
        new Thread(() -> collect(id, folder, chosen)).start();
    }

    private void collect(int id, boolean folder, Intent data) {
        ArrayList<String> names = new ArrayList<>();
        ArrayList<String> uris = new ArrayList<>();
        try {
            if (data != null && folder && data.getData() != null) {
                Uri tree = data.getData();
                String root = DocumentsContract.getTreeDocumentId(tree);
                String prefix = nameOf(DocumentsContract.buildDocumentUriUsingTree(tree, root)) + "/";
                walk(tree, root, prefix, names, uris);
            } else if (data != null) {
                ClipData clip = data.getClipData();
                if (clip != null) {
                    for (int i = 0; i < clip.getItemCount(); i++) add(clip.getItemAt(i).getUri(), names, uris);
                } else {
                    add(data.getData(), names, uris);
                }
            }
        } catch (RuntimeException e) {
            // What was found before it failed is the answer.
        }
        deliver(id, names, uris);
    }

    private void add(Uri uri, ArrayList<String> names, ArrayList<String> uris) {
        if (uri == null) return;
        names.add(nameOf(uri));
        uris.add(uri.toString());
    }

    /** Every file under a folder, named by its path inside it, as a page names a folder's files. */
    private void walk(Uri tree, String parent, String prefix, ArrayList<String> names, ArrayList<String> uris) {
        Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent);
        String[] columns = {
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        };
        try (Cursor cursor = getContentResolver().query(children, columns, null, null, null)) {
            while (cursor != null && cursor.moveToNext()) {
                String child = cursor.getString(0);
                String name = prefix + cursor.getString(1);
                if (DocumentsContract.Document.MIME_TYPE_DIR.equals(cursor.getString(2))) {
                    walk(tree, child, name + "/", names, uris);
                } else {
                    names.add(name);
                    uris.add(DocumentsContract.buildDocumentUriUsingTree(tree, child).toString());
                }
            }
        }
    }

    private String nameOf(Uri uri) {
        String[] columns = { OpenableColumns.DISPLAY_NAME };
        try (Cursor cursor = getContentResolver().query(uri, columns, null, null, null)) {
            if (cursor != null && cursor.moveToFirst() && cursor.getString(0) != null) return cursor.getString(0);
        } catch (RuntimeException e) {
            // A document with no name is still chosen.
        }
        String last = uri.getLastPathSegment();
        return last != null ? last : "";
    }

    private static void deliver(int id, ArrayList<String> names, ArrayList<String> uris) {
        try {
            answered(id, names.toArray(new String[0]), uris.toArray(new String[0]));
        } catch (UnsatisfiedLinkError e) {
            // No native half to tell: a process started afresh to hear its last one's answer.
        }
    }

    /** A file descriptor for one chosen document, or -1. The caller closes it. */
    public int openChosen(String uri) {
        try (ParcelFileDescriptor fd = getContentResolver().openFileDescriptor(Uri.parse(uri), "r")) {
            return fd == null ? -1 : fd.detachFd();
        } catch (Exception e) {
            return -1;
        }
    }
}
