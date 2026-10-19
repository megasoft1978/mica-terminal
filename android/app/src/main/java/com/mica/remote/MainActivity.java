package com.mica.remote;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.text.InputType;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.ViewOutlineProvider;
import android.text.TextUtils;
import android.widget.Button;
import android.widget.EditText;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ImageButton;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import android.text.TextWatcher;
import android.text.Editable;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

import com.google.zxing.integration.android.IntentIntegrator;
import com.google.zxing.integration.android.IntentResult;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.security.cert.Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

public final class MainActivity extends Activity {
    private static final int AUDIO_PERMISSION = 44;
    private static final String STATE_TAB_ID = "selected_tab_id";
    private static final String STATE_TAB_TITLE = "selected_tab_title";
    private static final String STATE_TAB_FOLDER = "selected_tab_folder";
    private static final String STATE_PROMPT = "draft_prompt";
    private static final int BG = Color.rgb(11, 13, 20);
    private static final int SURFACE = Color.rgb(22, 26, 38);
    private static final int SURFACE_ALT = Color.rgb(29, 34, 49);
    private static final int WHITE = Color.rgb(245, 246, 251);
    private static final int MUTED = Color.rgb(159, 168, 188);
    private static final int ACCENT = Color.rgb(133, 92, 246);
    private static final int MINT = Color.rgb(82, 225, 193);
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final AtomicBoolean refreshInFlight = new AtomicBoolean(false);
    private LinearLayout root, content, header, promptActions, detailRoot;
    private ScrollView scroll;
    private ScrollView terminalScroll;
    private ImageButton sendButton;
    private ImageButton dictateButton;
    private TextView status;
    private TextView terminalScreen;
    private TextView footer, terminalCount, detailStatus;
    private String baseUrl, pin, token;
    private String selectedId, selectedTitle;
    private String selectedFolder;
    private EditText prompt;
    private int lastTabCount;
    private String restoredPrompt;
    private JSONObject lastState;
    private SpeechRecognizer recognizer;
    private OnBackInvokedCallback terminalBackCallback;
    private boolean resumed;
    private String lastError;
    private String lastScreenText;
    private String lastRenderedState;
    private int listScrollY;
    private boolean destroyed;
    private volatile int pairingAttempt;
    private volatile int connectionGeneration;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(Color.rgb(17,19,26));
        getWindow().setNavigationBarColor(Color.rgb(17,19,26));
        baseUrl = secureGet("base"); pin = secureGet("pin"); token = secureGet("token");
        if (state != null) { selectedId=state.getString(STATE_TAB_ID); selectedTitle=state.getString(STATE_TAB_TITLE); selectedFolder=state.getString(STATE_TAB_FOLDER); restoredPrompt=state.getString(STATE_PROMPT); }
        renderShell();
        if (getIntent() != null && getIntent().getData() != null) { handlePairUri(getIntent().getData()); getIntent().setData(null); }
        if (paired()) { if (selectedId != null) { String id=selectedId,title=selectedTitle,folder=selectedFolder; openTab(id,title,folder); if(prompt!=null&&restoredPrompt!=null)prompt.setText(restoredPrompt); } else refresh(); } else renderPairing();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent); setIntent(intent);
        if (intent.getData() != null) { handlePairUri(intent.getData()); intent.setData(null); }
        renderShell(); if (paired()) refresh(); else renderPairing();
    }

    @Override protected void onResume() { super.onResume(); resumed = true; scheduleRefresh(); }
    @Override protected void onPause() { resumed = false; handler.removeCallbacks(refreshTick); stopDictation(); super.onPause(); }
    @Override protected void onDestroy() { destroyed=true; unregisterTerminalBack(); stopDictation(); io.shutdownNow(); super.onDestroy(); }

    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        state.putString(STATE_TAB_ID, selectedId); state.putString(STATE_TAB_TITLE, selectedTitle); state.putString(STATE_TAB_FOLDER, selectedFolder);
        if (prompt != null) state.putString(STATE_PROMPT, prompt.getText().toString());
    }

    @Override public void onBackPressed() {
        if (selectedId != null) { returnToTerminalList(); return; }
        super.onBackPressed();
    }

    private boolean paired() { return baseUrl != null && pin != null && token != null; }

    private void renderShell() {
        root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setBackgroundColor(BG);
        root.setPadding(dp(20), dp(14), dp(20), dp(14)); setContentView(root);
        header = new LinearLayout(this); header.setGravity(Gravity.CENTER_VERTICAL); header.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout brandBlock = new LinearLayout(this); brandBlock.setOrientation(LinearLayout.VERTICAL);
        TextView brand = text("mica", 28, WHITE); brand.setTypeface(Typeface.create("sans-serif", Typeface.BOLD)); brand.setContentDescription("Mica Remote");
        TextView brandCaption = text("REMOTE TERMINALS", 10, MUTED); brandCaption.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        brandCaption.setLetterSpacing(0.14f); brandBlock.addView(brand); brandBlock.addView(brandCaption);
        header.addView(brandBlock, new LinearLayout.LayoutParams(0, -2, 1));
        Button scan = button(paired() ? "Re-pair" : "＋  Pair"); scan.setOnClickListener(v -> scan());
        scan.setTextSize(14); scan.setPadding(dp(14), 0, dp(14), 0); scan.setBackground(rounded(ACCENT, 18)); header.addView(scan);
        root.addView(header);
        status = text("", 12, MINT); status.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        status.setPadding(dp(12), dp(8), dp(12), dp(8)); setStatus("Local network · pairing required", StatusTone.INFO);
        LinearLayout.LayoutParams statusParams = new LinearLayout.LayoutParams(-2, -2); statusParams.topMargin = dp(14); statusParams.bottomMargin = dp(16); root.addView(status, statusParams);
        scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.setClipToPadding(false); scroll.setVerticalScrollBarEnabled(false);
        content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL); scroll.addView(content);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        footer = text("Your Mac · your local network", 12, Color.rgb(110,119,141)); footer.setGravity(Gravity.CENTER); footer.setPadding(0, dp(12), 0, dp(2)); root.addView(footer);
    }

    private void renderPairing() {
        content.removeAllViews();
        TextView eyebrow = text("PRIVATE · LOCAL · SECURE", 11, MINT); eyebrow.setLetterSpacing(0.12f); eyebrow.setPadding(0, dp(24), 0, dp(8)); content.addView(eyebrow);
        TextView title = text("Your terminals,\nwherever you are.", 30, WHITE); title.setTypeface(Typeface.create("sans-serif", Typeface.BOLD)); content.addView(title);
        TextView desc = text("Pair with Mica on your Mac to see every project and terminal tab, then send a prompt or dictate one on your phone.", 16, MUTED); desc.setPadding(0, dp(12), 0, dp(24)); content.addView(desc);
        Button pair = button("Scan pairing code"); pair.setOnClickListener(v -> scan()); pair.setBackground(rounded(ACCENT, 16)); content.addView(pair);
    }

    private void scan() {
        IntentIntegrator integrator = new IntentIntegrator(this);
        integrator.setPrompt("Scan the Mica Remote QR code"); integrator.setBeepEnabled(false); integrator.setOrientationLocked(false);
        integrator.setDesiredBarcodeFormats(IntentIntegrator.QR_CODE); integrator.initiateScan();
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        IntentResult result = IntentIntegrator.parseActivityResult(requestCode, resultCode, data);
        if (result != null) { if (result.getContents() != null) acceptPayload(result.getContents()); return; }
        super.onActivityResult(requestCode, resultCode, data);
    }

    private void handlePairUri(Uri uri) {
        if ("pair".equals(uri.getHost())) acceptPayload(uri.toString());
    }

    private void acceptPayload(String raw) {
        try {
            Uri uri = Uri.parse(raw);
            if (!"mica".equals(uri.getScheme()) || !"pair".equals(uri.getHost())) throw new IllegalArgumentException("Not a Mica pairing code");
            String host = uri.getQueryParameter("host"), newPin = uri.getQueryParameter("pin"), code = uri.getQueryParameter("code");
            int port = Integer.parseInt(uri.getQueryParameter("port"));
            if (host == null || !host.matches("(?i)(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+local") || newPin == null || !newPin.matches("[0-9a-f]{64}") || code == null || !code.matches("[0-9]{6}") || port != 8765)
                throw new IllegalArgumentException("Pairing QR is incomplete");
            String newBase = "https://" + host + ":" + port;
            String deviceID = getPreferences(MODE_PRIVATE).getString("device_id", null);
            if (deviceID == null) { byte[] b = new byte[16]; new SecureRandom().nextBytes(b); StringBuilder s = new StringBuilder(); for(byte x:b)s.append(String.format(Locale.ROOT,"%02x",x)); deviceID=s.toString(); getPreferences(MODE_PRIVATE).edit().putString("device_id",deviceID).apply(); }
            String id = deviceID;
            final int attempt = ++pairingAttempt;
            ++connectionGeneration;
            setStatus("Verifying Mac certificate…", StatusTone.INFO);
            io.execute(() -> {
                try {
                    JSONObject body = new JSONObject(); body.put("code", code); body.put("deviceID", id); body.put("deviceName", android.os.Build.MANUFACTURER + " " + android.os.Build.MODEL);
                    JSONObject response = request(newBase, newPin, null, "POST", "/api/pair", body);
                    String receivedToken = response.getString("token");
                    if (receivedToken.isEmpty() || receivedToken.length() > 512 || !receivedToken.matches("[A-Za-z0-9._~-]+")) throw new java.io.IOException("Invalid pairing response");
                    if (attempt != pairingAttempt || destroyed) return;
                    if (!securePut("base",newBase) || !securePut("pin",newPin) || !securePut("token",receivedToken)) {
                        getSharedPreferences("remote-secure",MODE_PRIVATE).edit().clear().commit();
                        throw new java.io.IOException("Could not save secure pairing");
                    }
                    baseUrl=newBase; pin=newPin; token=receivedToken; ++connectionGeneration;
                    runOnUiThread(() -> { if (!destroyed && attempt == pairingAttempt) { setStatus("Paired securely", StatusTone.SUCCESS); refresh(); scheduleRefresh(); } });
                } catch (Exception e) { runOnUiThread(() -> { if (!destroyed && attempt == pairingAttempt) setStatus(pairingError(e), StatusTone.ERROR); }); }
            });
        } catch (Exception e) { toast(message(e)); }
    }

    private void refresh() {
        if (!paired()) { renderPairing(); return; }
        if (!refreshInFlight.compareAndSet(false, true)) return;
        String requestBase=baseUrl, requestPin=pin, requestToken=token; int generation=connectionGeneration;
        io.execute(() -> {
            try {
                JSONObject state = request(requestBase,requestPin,requestToken,"GET","/api/state",null);
                runOnUiThread(() -> { refreshInFlight.set(false); if (destroyed || generation != connectionGeneration) return; lastError=null; lastState=state; if (selectedId == null) renderState(state); else setStatus("Connected securely",StatusTone.SUCCESS); });
            } catch (Exception e) { runOnUiThread(() -> {
                refreshInFlight.set(false);
                if (destroyed || generation != connectionGeneration) return;
                lastError=message(e);
                setStatus("Mac unavailable · showing last sync", StatusTone.ERROR);
                if(detailStatus!=null){setStatus("Mac unavailable · terminal may be stale",StatusTone.ERROR);if(terminalScreen!=null)terminalScreen.setText("Terminal snapshot unavailable\n\nReconnect to your Mac to see the latest output.");}
                if (terminalCount != null && lastTabCount > 0) terminalCount.setText(lastTabCount + (lastTabCount == 1 ? " terminal · last synced" : " terminals · last synced"));
            }); }
        });
    }

    private final Runnable refreshTick = new Runnable() { @Override public void run() { if (resumed && paired()) { if(selectedId==null)refresh();else refreshScreen();handler.postDelayed(this, 1800); } } };
    private void scheduleRefresh() { handler.removeCallbacks(refreshTick); if (resumed && paired()) handler.postDelayed(refreshTick, 5000); }

    private void renderState(JSONObject state) {
        lastState=state;
        String stateKey=state.toString();
        if(stateKey.equals(lastRenderedState)) { setStatus("Connected securely", StatusTone.SUCCESS); return; }
        int scrollY=listScrollY;
        boolean preserveScroll=lastRenderedState!=null;
        lastRenderedState=stateKey;
        content.removeAllViews(); setStatus("Connected securely", StatusTone.SUCCESS);
        JSONArray projects = state.optJSONArray("projects");
        int totalTabs = 0; if (projects != null) for (int p=0; p<projects.length(); p++) { JSONObject project=projects.optJSONObject(p); if(project!=null&&project.optJSONArray("tabs")!=null)totalTabs+=project.optJSONArray("tabs").length(); }
        TextView pageTitle = text("Your workspace", 24, WHITE); pageTitle.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
        LinearLayout.LayoutParams titleParams = new LinearLayout.LayoutParams(-1,-2); titleParams.bottomMargin=dp(3); content.addView(pageTitle,titleParams);
        lastTabCount = totalTabs;
        terminalCount = text(totalTabs + (totalTabs == 1 ? " terminal · live" : " terminals · live"), 14, MUTED); terminalCount.setPadding(0,0,0,dp(18)); content.addView(terminalCount);
        if (projects == null || projects.length() == 0) { emptyState(content,"No active projects","Open a Mica project on your Mac and its terminal tabs will appear here."); return; }
        for (int p=0; p<projects.length(); p++) {
            JSONObject project = projects.optJSONObject(p); if(project==null)continue;
            String projectName=project.optString("name","Mica");
            TextView heading = text(projectName, 12, MUTED); heading.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL)); heading.setLetterSpacing(0.08f); heading.setPadding(0,dp(12),0,dp(9)); content.addView(heading);
            JSONArray tabs=project.optJSONArray("tabs"); if(tabs==null)continue;
            LinearLayout grid = new LinearLayout(this); grid.setOrientation(LinearLayout.VERTICAL);
            content.addView(grid, new LinearLayout.LayoutParams(-1, -2));
            for(int i=0;i<tabs.length();i++) {
                JSONObject tab=tabs.optJSONObject(i); if(tab==null)continue;
                String id=tab.optString("id"), title=tab.optString("name","Terminal"), subtitle=tab.optString("activity","Shell");
                String remoteFolder=tab.optString("folder","");
                final String folder=remoteFolder.isEmpty()?projectName:remoteFolder;
                boolean running=tab.optBoolean("running",true), selected=tab.optBoolean("selected",false);
                LinearLayout card=new LinearLayout(this); card.setOrientation(LinearLayout.HORIZONTAL); card.setGravity(Gravity.CENTER_VERTICAL); card.setPadding(dp(16),dp(15),dp(14),dp(15));
                card.setBackground(rounded(SURFACE,18)); card.setForeground(ripple());
                LinearLayout.LayoutParams cp = new LinearLayout.LayoutParams(-1, -2); cp.bottomMargin = dp(9); grid.addView(card, cp);
                TextView glyph=text("›_",18, MINT); glyph.setTypeface(Typeface.create("monospace",Typeface.BOLD)); glyph.setGravity(Gravity.CENTER); glyph.setBackground(rounded(Color.rgb(27,57,57),14));
                LinearLayout.LayoutParams gp=new LinearLayout.LayoutParams(dp(42),dp(42)); gp.rightMargin=dp(13); card.addView(glyph,gp);
                LinearLayout details=new LinearLayout(this); details.setOrientation(LinearLayout.VERTICAL);
                TextView name=text(title,18,WHITE); name.setTypeface(Typeface.create("sans-serif",Typeface.BOLD)); name.setMaxLines(2); name.setEllipsize(TextUtils.TruncateAt.END); name.setContentDescription("Terminal: "+title); details.addView(name);
                TextView activity=text(subtitle,13,MUTED); activity.setSingleLine(true); activity.setEllipsize(TextUtils.TruncateAt.END); LinearLayout.LayoutParams ap=new LinearLayout.LayoutParams(-1,-2); ap.topMargin=dp(4); details.addView(activity,ap);
                card.addView(details,new LinearLayout.LayoutParams(0,-2,1));
                TextView stateDot=text(running?"●":"○",13,running?MINT:MUTED); stateDot.setGravity(Gravity.CENTER); stateDot.setContentDescription(running?"Running":"Stopped");
                card.setContentDescription(title+", "+subtitle+", "+(running?"running":"stopped")+(selected?", active tab":""));
                LinearLayout.LayoutParams stateParams=new LinearLayout.LayoutParams(dp(24),dp(32)); stateParams.leftMargin=dp(5); card.addView(stateDot,stateParams);
                if(selected) card.setBackground(rounded(Color.rgb(31,37,56),18));
                card.setOnClickListener(v -> openTab(id,title,folder));
            }
        }
        Button forget=button("Forget this Mac"); forget.setTextColor(MUTED); forget.setBackground(rounded(SURFACE,14));
        LinearLayout.LayoutParams fp=new LinearLayout.LayoutParams(-1,dp(48)); fp.topMargin=dp(18); content.addView(forget,fp);
        forget.setOnClickListener(v -> new AlertDialog.Builder(this).setTitle("Forget this Mac?")
            .setMessage("This removes this phone’s secure pairing. You’ll need to scan the Mac’s QR code to connect again.")
            .setNegativeButton("Cancel", null).setPositiveButton("Forget", (dialog, which) -> {
                ++pairingAttempt; ++connectionGeneration; getSharedPreferences("remote-secure",MODE_PRIVATE).edit().clear().commit(); baseUrl=pin=token=null; selectedId=null; stopDictation(); renderPairing(); setStatus("Disconnected",StatusTone.INFO);
            }).show());
        if(preserveScroll) scroll.post(() -> scroll.scrollTo(0,scrollY));
    }

    private void openTab(String id,String title,String folder) {
        stopDictation();
        listScrollY=scroll.getScrollY();
        selectedId=id; selectedTitle=title; selectedFolder=folder; content.removeAllViews(); setStatus("Connected securely", StatusTone.SUCCESS);
        registerTerminalBack();
        boolean landscape = getResources().getConfiguration().orientation == Configuration.ORIENTATION_LANDSCAPE;
        header.setVisibility(View.GONE); status.setVisibility(View.GONE); scroll.setVisibility(View.GONE); footer.setVisibility(View.GONE);
        detailRoot=new LinearLayout(this); detailRoot.setOrientation(LinearLayout.VERTICAL); detailRoot.setPadding(dp(16),dp(8),dp(16),dp(12)); detailRoot.setBackgroundColor(BG);
        root.addView(detailRoot,new LinearLayout.LayoutParams(-1,0,1));
        LinearLayout titleRow=new LinearLayout(this); titleRow.setOrientation(LinearLayout.HORIZONTAL); titleRow.setGravity(Gravity.CENTER_VERTICAL);
        Button back=button("←  Back"); back.setGravity(Gravity.CENTER); back.setTextColor(WHITE); back.setBackground(rounded(SURFACE_ALT,14));
        back.setContentDescription("Back to terminal list");
        LinearLayout.LayoutParams bp=new LinearLayout.LayoutParams(-2,dp(48)); bp.rightMargin=dp(12); titleRow.addView(back,bp);
        back.setOnClickListener(v -> returnToTerminalList());
        LinearLayout titleBlock=new LinearLayout(this); titleBlock.setOrientation(LinearLayout.VERTICAL);
        TextView titleView=text(title,22,WHITE); titleView.setTypeface(Typeface.create("sans-serif",Typeface.BOLD)); titleView.setMaxLines(2); titleView.setEllipsize(TextUtils.TruncateAt.END); titleBlock.addView(titleView);
        if(folder!=null&&!folder.isEmpty()) { TextView folderView=text("⌁  "+folder,11,MUTED); folderView.setTypeface(Typeface.create("monospace",Typeface.NORMAL)); folderView.setSingleLine(true); folderView.setEllipsize(TextUtils.TruncateAt.MIDDLE); folderView.setContentDescription("Working folder: "+folder); titleBlock.addView(folderView); }
        detailStatus=text("Connected securely",12,MINT); detailStatus.setPadding(0,dp(2),0,0); titleBlock.addView(detailStatus);
        titleRow.addView(titleBlock,new LinearLayout.LayoutParams(0,-2,1)); detailRoot.addView(titleRow);
        lastScreenText=null;
        terminalScreen=text("Connecting to terminal…",13,Color.rgb(223,226,235)); terminalScreen.setTypeface(Typeface.create("monospace",Typeface.NORMAL)); terminalScreen.setPadding(dp(15),dp(15),dp(15),dp(15)); terminalScreen.setTextIsSelectable(true); terminalScreen.setHorizontallyScrolling(false); terminalScreen.setGravity(Gravity.TOP|Gravity.LEFT);
        terminalScroll=new ScrollView(this); terminalScroll.setVerticalScrollBarEnabled(true); terminalScroll.setFillViewport(true); terminalScroll.setBackground(rounded(Color.rgb(6,8,13),18)); terminalScroll.setClipToOutline(true); terminalScroll.addView(terminalScreen,new ScrollView.LayoutParams(-1,-2));
        LinearLayout.LayoutParams screenParams=new LinearLayout.LayoutParams(-1,0,1f); screenParams.topMargin=dp(10); screenParams.bottomMargin=dp(landscape?8:12); detailRoot.addView(terminalScroll,screenParams);
        refreshScreen();
        LinearLayout composer=new LinearLayout(this); composer.setOrientation(LinearLayout.HORIZONTAL); composer.setGravity(Gravity.CENTER_VERTICAL); composer.setPadding(dp(10),dp(6),dp(7),dp(6)); composer.setBackground(rounded(SURFACE_ALT,16));
        prompt=new EditText(this); prompt.setTextColor(WHITE); prompt.setHintTextColor(Color.rgb(128,137,158)); prompt.setHint("Write a prompt for "+title+"…"); prompt.setTextSize(16); prompt.setGravity(Gravity.TOP|Gravity.LEFT); prompt.setMinLines(landscape?1:2); prompt.setMaxLines(landscape?2:3); prompt.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_MULTI_LINE|InputType.TYPE_TEXT_FLAG_AUTO_CORRECT); prompt.setPadding(dp(6),dp(8),dp(6),dp(8)); prompt.setBackgroundColor(Color.TRANSPARENT);
        composer.addView(prompt,new LinearLayout.LayoutParams(0,-2,1));
        promptActions=new LinearLayout(this); promptActions.setOrientation(LinearLayout.HORIZONTAL); promptActions.setGravity(Gravity.CENTER_VERTICAL);
        dictateButton=new ImageButton(this); dictateButton.setImageResource(R.drawable.ic_mic); dictateButton.setContentDescription("Dictate prompt"); dictateButton.setTooltipText("Dictate prompt"); dictateButton.setScaleType(android.widget.ImageView.ScaleType.CENTER); dictateButton.setBackground(rounded(Color.TRANSPARENT,14)); dictateButton.setForeground(ripple()); dictateButton.setOnClickListener(v -> dictate()); promptActions.addView(dictateButton,new LinearLayout.LayoutParams(dp(48),dp(48)));
        sendButton=new ImageButton(this); sendButton.setImageResource(R.drawable.ic_send); sendButton.setContentDescription("Send prompt"); sendButton.setTooltipText("Send prompt"); sendButton.setScaleType(android.widget.ImageView.ScaleType.CENTER); sendButton.setBackground(rounded(ACCENT,14)); sendButton.setForeground(ripple()); sendButton.setOnClickListener(v -> sendPrompt()); LinearLayout.LayoutParams sp=new LinearLayout.LayoutParams(dp(48),dp(48)); sp.leftMargin=dp(2); promptActions.addView(sendButton,sp);
        composer.addView(promptActions,new LinearLayout.LayoutParams(-2,-2));
        prompt.setImeOptions(EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_ENTER_ACTION);
        prompt.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s,int start,int count,int after){}
            @Override public void onTextChanged(CharSequence s,int start,int before,int count){updateComposerState();}
            @Override public void afterTextChanged(Editable e){}
        });
        prompt.setOnEditorActionListener((view, actionId, event) -> {
            if(actionId==EditorInfo.IME_ACTION_SEND || (event!=null && event.getKeyCode()==KeyEvent.KEYCODE_ENTER && event.getAction()==KeyEvent.ACTION_DOWN && event.isCtrlPressed())) { sendPrompt(); return true; }
            return false;
        });
        updateComposerState();
        LinearLayout.LayoutParams composerParams=new LinearLayout.LayoutParams(-1,-2); composerParams.bottomMargin=dp(4); detailRoot.addView(composer,composerParams);
        if(lastError!=null){setStatus("Mac unavailable · terminal may be stale",StatusTone.ERROR);if(terminalScreen!=null)terminalScreen.setText("Terminal snapshot unavailable\n\nReconnect to your Mac to see the latest output.");}
    }

    private void returnToTerminalList() {
        stopDictation();
        if (android.os.Build.VERSION.SDK_INT >= 33 && terminalBackCallback != null) handler.postDelayed(this::unregisterTerminalBack, 400);
        hidePromptKeyboard();
        if (detailRoot != null) root.removeView(detailRoot);
        detailRoot=null;
        prompt = null; promptActions = null; dictateButton=null; detailStatus=null; header.setVisibility(View.VISIBLE); status.setVisibility(View.VISIBLE); footer.setVisibility(View.VISIBLE);
        scroll.setVisibility(View.VISIBLE);
        selectedId=null; selectedTitle=null; selectedFolder=null; terminalScreen=null; terminalScroll=null; sendButton=null; lastScreenText=null;
        if (lastState != null) {
            lastRenderedState=null;
            renderState(lastState);
            setStatus("Reconnecting · last sync shown",StatusTone.INFO);
            if (terminalCount != null && lastTabCount > 0) terminalCount.setText(lastTabCount + (lastTabCount == 1 ? " terminal · last synced" : " terminals · last synced"));
        } else {
            content.removeAllViews(); emptyState(content,"Reconnecting to your Mac","Your terminal list will appear here when the local connection is available.");
            setStatus("Reconnecting…",StatusTone.INFO);
        }
        refresh();
    }

    private void registerTerminalBack() {
        if (android.os.Build.VERSION.SDK_INT < 33 || terminalBackCallback != null) return;
        terminalBackCallback = () -> {
            if (selectedId != null) {
                returnToTerminalList();
            }
        };
        getOnBackInvokedDispatcher().registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_OVERLAY, terminalBackCallback);
    }

    private void unregisterTerminalBack() {
        if (android.os.Build.VERSION.SDK_INT >= 33 && terminalBackCallback != null) {
            getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(terminalBackCallback);
            terminalBackCallback = null;
        }
    }

    private void refreshScreen() {
        if(selectedId==null||terminalScreen==null||!paired())return;
        if(!refreshInFlight.compareAndSet(false,true))return;
        String id=selectedId;TextView target=terminalScreen; String requestBase=baseUrl,requestPin=pin,requestToken=token; int generation=connectionGeneration;
        io.execute(() -> { try { JSONObject result=request(requestBase,requestPin,requestToken,"GET","/api/screen?id="+Uri.encode(id),null); runOnUiThread(()->{refreshInFlight.set(false);if(!destroyed&&generation==connectionGeneration&&id.equals(selectedId)&&target==terminalScreen){lastError=null;String screen=compactScreen(result.optString("text",""));if(screen.isEmpty())screen="No terminal output yet.";if(!screen.equals(lastScreenText)){boolean follow=lastScreenText==null||terminalScroll==null||terminalScroll.getChildAt(0).getHeight()-terminalScroll.getScrollY()-terminalScroll.getHeight()<=dp(24);int oldY=terminalScroll==null?0:terminalScroll.getScrollY();target.setText(screen);lastScreenText=screen;if(terminalScroll!=null)terminalScroll.post(()->{if(follow)terminalScroll.fullScroll(View.FOCUS_DOWN);else terminalScroll.scrollTo(0,oldY);});}}}); } catch(Exception e){runOnUiThread(()->{refreshInFlight.set(false);if(!destroyed&&generation==connectionGeneration&&id.equals(selectedId)&&target==terminalScreen){lastError=message(e);setStatus("Mac unavailable · terminal may be stale",StatusTone.ERROR);}});} });
    }

    private String compactScreen(String screen) {
        String[] lines=screen.split("\\n",-1);int end=lines.length;
        while(end>0&&lines[end-1].trim().isEmpty())end--;
        String compact=String.join("\n",Arrays.copyOf(lines,end));StringBuilder safe=new StringBuilder(Math.min(compact.length(),100000));
        for(int i=0;i<compact.length()&&safe.length()<100000;i++){char c=compact.charAt(i);if(c=='\n'||c=='\t'||c=='\r'||(c>=0x20&&!isBidiControl(c)))safe.append(c);}
        return safe.toString();
    }

    private boolean isBidiControl(char c) { return c==0x061c||c==0x200e||c==0x200f||(c>=0x202a&&c<=0x202e)||(c>=0x2066&&c<=0x2069); }

    private void sendPrompt() {
        String text=prompt==null?"":prompt.getText().toString().trim(); if(text.isEmpty()){toast("Write or dictate a prompt first");return;}
        if(sendButton!=null&&!sendButton.isEnabled())return;
        if(sendButton!=null)sendButton.setEnabled(false);
        String id=selectedId,targetTitle=selectedTitle; String requestBase=baseUrl,requestPin=pin,requestToken=token; int generation=connectionGeneration; setStatus("Sending to "+targetTitle+"…",StatusTone.INFO);
        io.execute(() -> { try { JSONObject body=new JSONObject();body.put("id",id);body.put("text",text);request(requestBase,requestPin,requestToken,"POST","/api/input",body);runOnUiThread(()->{if(!destroyed&&generation==connectionGeneration&&id.equals(selectedId)&&prompt!=null){prompt.setText("");hidePromptKeyboard();setStatus("Prompt sent to "+targetTitle,StatusTone.SUCCESS);}if(!destroyed&&sendButton!=null)sendButton.setEnabled(true);}); } catch(Exception e){runOnUiThread(()->{if(!destroyed&&generation==connectionGeneration&&id.equals(selectedId))setStatus("Prompt not sent · check connection",StatusTone.ERROR);if(!destroyed&&sendButton!=null)sendButton.setEnabled(true);});} });
    }

    private void updateComposerState() {
        if (sendButton == null || prompt == null) return;
        boolean hasDraft = !prompt.getText().toString().trim().isEmpty();
        sendButton.setEnabled(hasDraft);
        sendButton.setAlpha(hasDraft ? 1f : 0.48f);
        sendButton.setContentDescription(hasDraft ? "Send prompt" : "Send prompt; enter text first");
    }

    private void dictate() {
        if (BuildVersion.sdk() < 31 || !SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) { toast("On-device speech recognition is unavailable on this phone"); return; }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED) { requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO},AUDIO_PERMISSION);return; }
        if (recognizer != null) recognizer.destroy();
        recognizer=SpeechRecognizer.createOnDeviceSpeechRecognizer(this);
        SpeechRecognizer activeRecognizer=recognizer; EditText targetPrompt=prompt; String targetTab=selectedId;
        recognizer.setRecognitionListener(new RecognitionListener() {
            @Override public void onReadyForSpeech(Bundle b){if(!destroyed&&resumed&&recognizer==activeRecognizer&&prompt==targetPrompt&&java.util.Objects.equals(selectedId,targetTab))setStatus("Listening · on this device",StatusTone.INFO);}
            @Override public void onResults(Bundle b){if(destroyed||!resumed||recognizer!=activeRecognizer||prompt!=targetPrompt||!java.util.Objects.equals(selectedId,targetTab))return;ArrayList<String> matches=b.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);if(matches!=null&&!matches.isEmpty()){int at=targetPrompt.getSelectionStart();targetPrompt.getText().insert(Math.max(at,0),matches.get(0));}setStatus("Dictation added to draft",StatusTone.SUCCESS);}
            @Override public void onError(int e){if(!destroyed&&recognizer==activeRecognizer)setStatus(e==SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED?"Offline language unavailable":"Dictation stopped",StatusTone.INFO);}
            @Override public void onBeginningOfSpeech(){} @Override public void onRmsChanged(float r){} @Override public void onBufferReceived(byte[] b){} @Override public void onEndOfSpeech(){} @Override public void onPartialResults(Bundle b){} @Override public void onEvent(int t,Bundle b){}
        });
        Intent intent=new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE,Locale.getDefault());intent.putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE,true);intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS,true);
        try { recognizer.startListening(intent); } catch(Exception e){toast("Could not start on-device dictation");}
    }

    private void stopDictation() { if(recognizer!=null){try{recognizer.cancel();}catch(Exception ignored){}recognizer.destroy();recognizer=null;} }

    private JSONObject request(String base,String expectedPin,String bearer,String method,String path,JSONObject body) throws Exception {
        if(base==null||!base.matches("https://[A-Za-z0-9.-]+\\.local:8765")||expectedPin==null||!expectedPin.matches("[0-9a-f]{64}")||!path.startsWith("/api/"))throw new java.io.IOException("Invalid remote endpoint");
        URL endpoint=new URL(base+path);
        HttpsURLConnection connection=(HttpsURLConnection)endpoint.openConnection(); connection.setInstanceFollowRedirects(false);connection.setConnectTimeout(4500);connection.setReadTimeout(5000);connection.setRequestMethod(method);connection.setRequestProperty("Accept","application/json");
        connection.setSSLSocketFactory(pinnedContext(expectedPin,endpoint.getHost()).getSocketFactory());
        if(bearer!=null)connection.setRequestProperty("Authorization","Bearer "+bearer);
        if(body!=null){byte[] encoded=body.toString().getBytes(StandardCharsets.UTF_8);if(encoded.length>8192)throw new java.io.IOException("Request body too large");connection.setDoOutput(true);connection.setRequestProperty("Content-Type","application/json; charset=utf-8");connection.setFixedLengthStreamingMode(encoded.length);try(OutputStream out=connection.getOutputStream()){out.write(encoded);}}
        int code=connection.getResponseCode();InputStream in=code<400?connection.getInputStream():connection.getErrorStream();ByteArrayOutputStream bytes=new ByteArrayOutputStream();if(in!=null){byte[] chunk=new byte[4096];int n;while((n=in.read(chunk))>=0){if(bytes.size()+n>1_000_000)throw new java.io.IOException("Remote response too large");bytes.write(chunk,0,n);}in.close();}connection.disconnect();
        String value=bytes.toString(StandardCharsets.UTF_8.name());if(code<200||code>=300)throw new java.io.IOException("HTTP "+code);return new JSONObject(value);
    }

    private SSLContext pinnedContext(String expectedPin,String expectedHost) throws Exception {
        X509TrustManager manager=new X509TrustManager(){
            @Override public void checkClientTrusted(java.security.cert.X509Certificate[] c,String a) throws java.security.cert.CertificateException { throw new java.security.cert.CertificateException("Client certificates are not accepted"); }
            @Override public void checkServerTrusted(java.security.cert.X509Certificate[] chain,String auth) throws java.security.cert.CertificateException {
                if(chain==null||chain.length==0)throw new java.security.cert.CertificateException("Missing server certificate");
                try { StringBuilder hex=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(chain[0].getEncoded()))hex.append(String.format(Locale.ROOT,"%02x",b));if(!hex.toString().equals(expectedPin))throw new java.security.cert.CertificateException("Mac certificate pin changed; scan its QR again");chain[0].checkValidity();boolean hostMatched=false;java.util.Collection<List<?>> names=chain[0].getSubjectAlternativeNames();if(names!=null)for(List<?> name:names)if(name.size()>1&&Integer.valueOf(2).equals(name.get(0))&&expectedHost.equalsIgnoreCase(String.valueOf(name.get(1))))hostMatched=true;if(!hostMatched)throw new java.security.cert.CertificateException("Mac certificate does not match pairing host"); }
                catch(java.security.cert.CertificateException e){throw e;}catch(Exception e){throw new java.security.cert.CertificateException(e);}
            }
            @Override public java.security.cert.X509Certificate[] getAcceptedIssuers(){return new java.security.cert.X509Certificate[0];}
        };
        SSLContext context=SSLContext.getInstance("TLS");context.init(null,new TrustManager[]{manager},new SecureRandom());return context;
    }

    private SecretKey secureKey() throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");store.load(null);
        java.security.Key existing=store.getKey("mica-remote-v1",null);if(existing instanceof SecretKey)return (SecretKey)existing;
        KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder("mica-remote-v1",KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setRandomizedEncryptionRequired(true).build());
        return generator.generateKey();
    }
    private String secureGet(String key) {
        try { String stored=getSharedPreferences("remote-secure",MODE_PRIVATE).getString(key,null);if(stored==null)return null;byte[] all=android.util.Base64.decode(stored,android.util.Base64.NO_WRAP);byte[] iv=java.util.Arrays.copyOfRange(all,0,12);byte[] cipher=java.util.Arrays.copyOfRange(all,12,all.length);Cipher c=Cipher.getInstance("AES/GCM/NoPadding");c.init(Cipher.DECRYPT_MODE,secureKey(),new GCMParameterSpec(128,iv));return new String(c.doFinal(cipher),StandardCharsets.UTF_8); }
        catch(Exception e){return null;}
    }
    private boolean securePut(String key,String value) {
        try { Cipher c=Cipher.getInstance("AES/GCM/NoPadding");c.init(Cipher.ENCRYPT_MODE,secureKey());byte[] iv=c.getIV();byte[] encrypted=c.doFinal(value.getBytes(StandardCharsets.UTF_8));byte[] all=new byte[iv.length+encrypted.length];System.arraycopy(iv,0,all,0,iv.length);System.arraycopy(encrypted,0,all,iv.length,encrypted.length);return getSharedPreferences("remote-secure",MODE_PRIVATE).edit().putString(key,android.util.Base64.encodeToString(all,android.util.Base64.NO_WRAP)).commit(); }
        catch(Exception e){return false;}
    }

    private enum StatusTone { SUCCESS, INFO, ERROR }
    private void setStatus(String message,StatusTone tone) {
        if(status==null)return;
        int color=tone==StatusTone.SUCCESS?MINT:tone==StatusTone.ERROR?Color.rgb(255,146,156):Color.rgb(190,177,255);
        int background=tone==StatusTone.SUCCESS?Color.rgb(19,45,44):tone==StatusTone.ERROR?Color.rgb(57,30,41):Color.rgb(39,34,61);
        status.setText("  ●  "+message); status.setTextColor(color); status.setBackground(rounded(background,20));
        status.setContentDescription(message); status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        if(detailStatus!=null){detailStatus.setText("●  "+message);detailStatus.setTextColor(color);detailStatus.setContentDescription(message);}
    }
    private String pairingError(Exception e) {
        StringBuilder detail=new StringBuilder();
        for(Throwable cause=e;cause!=null;cause=cause.getCause())detail.append(' ').append(cause.getMessage());
        String value=detail.toString().toLowerCase(Locale.ROOT);
        if(value.contains("certificate pin changed"))return "Mac certificate changed · scan its current QR";
        if(value.contains("http 401")||value.contains("http 403"))return "Pairing code expired · scan a new QR";
        return "Pairing failed · check Wi-Fi and scan the current QR";
    }
    private void hidePromptKeyboard() {
        View target=prompt!=null?prompt:getCurrentFocus();
        if(target!=null){((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(target.getWindowToken(),0);target.clearFocus();}
    }
    private TextView text(String s,int size,int color){TextView t=new TextView(this);t.setText(s);t.setTextSize(size);t.setTextColor(color);return t;}
    private Button button(String s){Button b=new Button(this);b.setText(s);b.setAllCaps(false);b.setTextColor(WHITE);b.setTextSize(14);b.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));b.setMinHeight(dp(48));b.setPadding(dp(12),0,dp(12),0);b.setBackground(rounded(SURFACE_ALT,14));b.setStateListAnimator(null);return b;}
    private GradientDrawable rounded(int color,int radiusDp){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radiusDp));return d;}
    private android.graphics.drawable.Drawable ripple(){return new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(Color.argb(28,255,255,255)),null,rounded(Color.WHITE,18));}
    private void emptyState(LinearLayout parent,String title,String message){LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(18),dp(20),dp(18),dp(20));box.setBackground(rounded(SURFACE,18));TextView h=text(title,19,WHITE);h.setTypeface(Typeface.DEFAULT,Typeface.BOLD);box.addView(h);TextView body=text(message,14,MUTED);body.setPadding(0,dp(7),0,0);box.addView(body);parent.addView(box);}
    private int dp(float value){return (int)(value*getResources().getDisplayMetrics().density+0.5f);}
    private String message(Exception e){return e.getMessage()==null?e.getClass().getSimpleName():e.getMessage();}
    private void toast(String s){Toast.makeText(this,s,Toast.LENGTH_LONG).show();}
    @Override public void onRequestPermissionsResult(int r,String[] p,int[] g){super.onRequestPermissionsResult(r,p,g);if(r==AUDIO_PERMISSION&&g.length>0&&g[0]==PackageManager.PERMISSION_GRANTED)dictate();}
    private static final class BuildVersion { static int sdk(){return android.os.Build.VERSION.SDK_INT;} }
}
