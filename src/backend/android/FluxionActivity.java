// SPDX-License-Identifier: BSL-1.0
//
// The one piece of Java fluxion-platform has: a NativeActivity that hears the
// answer to an activity it started, and that has a text field for a soft
// keyboard to type into. NativeActivity never hands onActivityResult to native
// code, and the system's document picker answers nowhere else; and it has no
// InputConnection, so a soft keyboard has nowhere to put what it types. An app
// names this class in its manifest where it would name
// android.app.NativeActivity, and packs `zig build android-dex`'s classes.dex
// into its APK - see the README.

package dev.fluxion.platform;

import android.app.Dialog;
import android.app.NativeActivity;
import android.content.ClipData;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.text.Editable;
import android.text.InputFilter;
import android.text.InputType;
import android.text.TextWatcher;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.webkit.MimeTypeMap;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;

// It is the bar's TextWatcher itself: `android-dex` compiles one class file,
// so there is no inner class to be one.
public class FluxionActivity extends NativeActivity implements TextWatcher {
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

    // ------------------------------------------------------------------
    // The text bar
    // ------------------------------------------------------------------

    /** What the person typed into the bar, and where its caret is, in UTF-16 units. */
    private static native void textBarEdited(String text, int start, int end);

    /** The bar put away: by its Done or Enter (`submitted`), or by back or a tap past it. */
    private static native void textBarDone(boolean submitted);

    /**
     * A text field above the soft keyboard, in a window of its own, so the
     * keyboard pushes it up rather than the program's surface: the person
     * sees what they type while the keyboard covers the program's own field.
     */
    private Dialog bar;
    private LinearLayout barRow;
    private EditText barText;
    private Button barButton;
    /** The button's own background, for the bar's own look. */
    private Drawable barButtonLook;
    /** Set while the program writes the bar, so the change is not sent back to it. */
    private boolean barQuiet;
    private boolean barMultiline;

    /** Show the bar with this text, or bring an open one up to it. Called on the program's thread. */
    public void showTextBar(String text, int start, int end, boolean password, boolean multiline, int maxLength, String hint) {
        runOnUiThread(() -> openBar(text, start, end, password, multiline, maxLength, hint));
    }

    /**
     * The program's own look for the bar - its field's, its button's, its
     * panel's - so it looks like the field it stands for; or, with `own`
     * false, the bar's. Colours are ARGB, sizes pixels, and `font` a face's
     * file or null. Called on the program's thread, which writes the face
     * out where `Typeface` can read it.
     */
    public void setTextBarLook(boolean own, int barColor,
            int field, int fieldBorder, float fieldBorderWidth, float fieldRadius, float fieldPaddingX, float fieldPaddingY, int text, int hint, float textSize,
            int button, int buttonBorder, float buttonBorderWidth, float buttonRadius, float buttonPaddingX, float buttonPaddingY, int buttonText,
            byte[] font) {
        Typeface face = own && font != null ? faceOf(font) : null;
        runOnUiThread(() -> {
            if (bar == null) makeBar();
            if (!own) {
                plainLook();
                return;
            }
            barRow.setBackgroundColor(barColor);
            barText.setBackground(box(field, fieldBorder, fieldBorderWidth, fieldRadius));
            barText.setPadding(Math.round(fieldPaddingX), Math.round(fieldPaddingY), Math.round(fieldPaddingX), Math.round(fieldPaddingY));
            barText.setTextColor(text);
            barText.setHintTextColor(hint);
            barText.setTextSize(TypedValue.COMPLEX_UNIT_PX, textSize);
            barText.setTypeface(face);
            barButton.setBackground(box(button, buttonBorder, buttonBorderWidth, buttonRadius));
            barButton.setPadding(Math.round(buttonPaddingX), Math.round(buttonPaddingY), Math.round(buttonPaddingX), Math.round(buttonPaddingY));
            barButton.setTextColor(buttonText);
            barButton.setTextSize(TypedValue.COMPLEX_UNIT_PX, textSize);
            barButton.setTypeface(face);
        });
    }

    /** The bar's own look: a dark field with white text, and the system's button. */
    private void plainLook() {
        float density = getResources().getDisplayMetrics().density;
        int padding = (int) (8 * density);
        barRow.setBackgroundColor(0xF0202024);
        barText.setBackground(box(0xFF2E2E34, 0xFF5A5A66, Math.max(1, density), 6 * density));
        barText.setPadding(padding + padding / 2, padding, padding + padding / 2, padding);
        barText.setTextColor(Color.WHITE);
        barText.setHintTextColor(0xFF8A8A94);
        barText.setTextSize(18);
        barText.setTypeface(null);
        barButton.setBackground(barButtonLook);
        barButton.setTextColor(Color.BLACK);
        barButton.setTextSize(14);
        barButton.setTypeface(null);
    }

    private static GradientDrawable box(int fill, int edge, float width, float radius) {
        GradientDrawable box = new GradientDrawable();
        box.setColor(fill);
        box.setCornerRadius(radius);
        if (width > 0) box.setStroke(Math.max(1, Math.round(width)), edge);
        return box;
    }

    /** A face from a file's bytes, written where `Typeface` reads from; null when it cannot be read. */
    private Typeface faceOf(byte[] font) {
        File file = new File(getCacheDir(), "text-bar-face");
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(font);
        } catch (IOException e) {
            return null;
        }
        try {
            return Typeface.createFromFile(file);
        } catch (RuntimeException e) {
            return null;
        }
    }

    /** Put the bar away without a word back: the program asked. */
    public void hideTextBar() {
        runOnUiThread(() -> {
            if (bar != null && bar.isShowing()) bar.dismiss();
        });
    }

    private void openBar(String text, int start, int end, boolean password, boolean multiline, int maxLength, String hint) {
        if (bar == null) makeBar();
        barQuiet = true;
        barText.setHint(hint);
        barMultiline = multiline;
        int type = InputType.TYPE_CLASS_TEXT;
        if (password) type |= InputType.TYPE_TEXT_VARIATION_PASSWORD;
        if (multiline) type |= InputType.TYPE_TEXT_FLAG_MULTI_LINE;
        if (barText.getInputType() != type) barText.setInputType(type);
        barText.setMaxLines(multiline ? 4 : 1);
        barText.setFilters(maxLength > 0 ? new InputFilter[] { new InputFilter.LengthFilter(maxLength) } : new InputFilter[0]);
        if (!barText.getText().toString().equals(text)) barText.setText(text);
        int length = barText.length();
        barText.setSelection(Math.max(0, Math.min(start, length)), Math.max(0, Math.min(end, length)));
        barQuiet = false;
        // The window asks for the keyboard as it takes the focus.
        if (!bar.isShowing()) {
            bar.show();
            barText.requestFocus();
        }
    }

    private void makeBar() {
        float density = getResources().getDisplayMetrics().density;
        int padding = (int) (8 * density);

        barText = new EditText(this);
        // The bar is the field: never the keyboard's own full-screen one.
        barText.setImeOptions(EditorInfo.IME_ACTION_DONE | EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN);
        barText.addTextChangedListener(this);
        barText.setOnEditorActionListener((view, action, key) -> {
            boolean enter = key != null && key.getKeyCode() == KeyEvent.KEYCODE_ENTER && key.getAction() == KeyEvent.ACTION_DOWN;
            if (action == EditorInfo.IME_ACTION_DONE || (enter && !barMultiline)) {
                finishBar(true);
                return true;
            }
            return false;
        });

        barButton = new Button(this);
        barButton.setText(android.R.string.ok);
        barButton.setOnClickListener(view -> finishBar(true));
        barButtonLook = barButton.getBackground();

        barRow = new LinearLayout(this);
        barRow.setOrientation(LinearLayout.HORIZONTAL);
        barRow.setGravity(Gravity.CENTER_VERTICAL);
        barRow.setPadding(padding, padding / 2, padding, padding / 2);
        barRow.addView(barText, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        LinearLayout.LayoutParams beside = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        beside.setMarginStart(padding);
        barRow.addView(barButton, beside);

        // In the bar's own look until the program gives its own.
        plainLook();

        bar = new Dialog(this);
        bar.requestWindowFeature(Window.FEATURE_NO_TITLE);
        bar.setContentView(barRow);
        // Back, or a tap past it: done, and not submitted.
        bar.setCanceledOnTouchOutside(true);
        bar.setOnCancelListener(dialog -> textDone(false));
        Window window = bar.getWindow();
        window.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
        window.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        window.setGravity(Gravity.BOTTOM);
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE | WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
    }

    private void finishBar(boolean submitted) {
        if (bar != null && bar.isShowing()) bar.dismiss();
        textDone(submitted);
    }

    private static void textDone(boolean submitted) {
        try {
            textBarDone(submitted);
        } catch (UnsatisfiedLinkError e) {
            // No native half to tell.
        }
    }

    @Override
    public void beforeTextChanged(CharSequence text, int start, int count, int after) {}

    @Override
    public void onTextChanged(CharSequence text, int start, int before, int count) {}

    /** Every change, whole: what the keyboard composes is part of it until it commits. */
    @Override
    public void afterTextChanged(Editable text) {
        if (barQuiet) return;
        try {
            textBarEdited(text.toString(), barText.getSelectionStart(), barText.getSelectionEnd());
        } catch (UnsatisfiedLinkError e) {
            // No native half to tell.
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
