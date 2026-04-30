#!/usr/bin/perl -w
#
# hotspotlogin.cgi — Captive Portal login for CoovaChilli UAM.
#
# Standard Coova UAM flow (re-implemented; coova-chilli 1.6 ships only the
# miniportal *.chi flow which is tightly coupled to chilli's internal miniweb
# at port 3990 and breaks when served via Apache).
#
# Flow:
#   1. chilli redirects unauth client to:
#      http://<uamlisten>/cgi-bin/hotspotlogin.cgi?res=notyet&challenge=<hex>
#         &uamip=<chilli-ip>&uamport=<chilli-port>&userurl=<orig-url>&...
#   2. CGI shows login form.
#   3. User submits → CGI computes CHAP password (md5(challenge+uamsecret) XOR pass)
#      and redirects browser to:
#      http://<uamip>:<uamport>/logon?username=...&response=<hex>&userurl=...
#   4. chilli does RADIUS auth, redirects back to
#      hotspotlogin.cgi?res=success or res=failed.
#   5. CGI shows result page.

use strict;
use CGI qw(:standard escapeHTML);
use Digest::MD5 qw(md5_hex);

# Read uamsecret from /etc/chilli/defaults (HS_UAMSECRET=...)
my $uamsecret = '';
if (open(my $fh, '<', '/etc/chilli/defaults')) {
    while (my $line = <$fh>) {
        if ($line =~ /^\s*HS_UAMSECRET\s*=\s*['"]?([^'"\s]+)/) {
            $uamsecret = $1;
            last;
        }
    }
    close $fh;
}

my $q = CGI->new;

my $res       = $q->param('res')       || '';
my $challenge = $q->param('challenge') || '';
my $uamip     = $q->param('uamip')     || '';
my $uamport   = $q->param('uamport')   || '';
my $userurl   = $q->param('userurl')   || 'http://www.google.com/';
my $reply     = $q->param('reply')     || '';
my $UserName  = $q->param('UserName')  || '';
my $Password  = $q->param('Password')  || '';

my $logo_url  = '/logo.svg';
my $css_url   = '/style.css';

print $q->header(
    -type    => 'text/html; charset=utf-8',
    -charset => 'utf-8',
    -expires => '-1d',
    -Cache_Control => 'no-store',
);

sub html_header {
    my ($title) = @_;
    return <<"HTML";
<!DOCTYPE html>
<html lang="zh-Hant">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$title</title>
  <link rel="stylesheet" href="$css_url">
</head>
<body>
<main class="cp-container">
  <img src="$logo_url" alt="Logo" class="cp-logo">
HTML
}

sub html_footer {
    return <<"HTML";
  <div class="cp-footer">遇到問題請聯繫網路管理員</div>
</main>
</body>
</html>
HTML
}

# --- res=success ---
if ($res eq 'success') {
    print html_header('登入成功');
    print qq{<h1 class="cp-title">登入成功</h1>};
    print qq{<p class="cp-subtitle">您已經連上網路。</p>};
    print qq{<p style="text-align:center"><a class="cp-button" href="} . escapeHTML($userurl) . qq{">繼續瀏覽</a></p>};
    print html_footer();
    exit 0;
}

# --- res=failed ---
if ($res eq 'failed') {
    print html_header('登入失敗');
    print qq{<h1 class="cp-title">登入失敗</h1>};
    print qq{<p class="cp-error">} . escapeHTML($reply || '帳號或密碼錯誤') . qq{</p>};
    print qq{<p><a class="cp-button" href="javascript:history.back()">重試</a></p>};
    print html_footer();
    exit 0;
}

# --- res=logoff ---
if ($res eq 'logoff') {
    print html_header('已登出');
    print qq{<h1 class="cp-title">已登出</h1>};
    print qq{<p class="cp-subtitle">已斷線。</p>};
    print html_footer();
    exit 0;
}

# --- Submitted credentials → compute CHAP and redirect to chilli /logon ---
if ($UserName ne '' && $Password ne '' && $challenge ne '' && $uamip ne '' && $uamport ne '') {
    # Coova UAM CHAP password formula (matches reference hotspotlogin.cgi):
    #   hexchal = challenge as binary (16 bytes from 32 hex chars)
    #   newchal = md5(hexchal . uamsecret)   (binary 16 bytes)
    #   response = md5("\0" . password . newchal)   (hex 32 chars)
    my $hexchal = pack('H32', $challenge);
    my $newchal = $uamsecret ne ''
        ? pack('H*', md5_hex($hexchal . $uamsecret))
        : $hexchal;
    my $response = md5_hex("\0" . $Password . $newchal);

    my $logon_url = sprintf(
        'http://%s:%s/logon?username=%s&response=%s&userurl=%s',
        $uamip, $uamport,
        $q->escape($UserName),
        $response,
        $q->escape($userurl),
    );

    print html_header('登入中...');
    print qq{<h1 class="cp-title">登入中…</h1>};
    print qq{<p class="cp-subtitle">請稍候。</p>};
    print qq{<meta http-equiv="refresh" content="0;url=$logon_url">};
    print qq{<script>window.location='$logon_url';</script>};
    print qq{<p><a href="$logon_url">如未自動跳轉，請點此</a></p>};
    print html_footer();
    exit 0;
}

# --- Default: render login form (res=notyet or unset) ---
print html_header('使用者登入');
print qq{<h1 class="cp-title">使用者登入</h1>};
print qq{<p class="cp-subtitle">請輸入帳號密碼以連線網路</p>};

print qq{<form class="cp-form" method="POST" action="/cgi-bin/hotspotlogin.cgi">};
print qq{<input type="hidden" name="challenge" value="} . escapeHTML($challenge) . qq{">};
print qq{<input type="hidden" name="uamip"     value="} . escapeHTML($uamip) . qq{">};
print qq{<input type="hidden" name="uamport"   value="} . escapeHTML($uamport) . qq{">};
print qq{<input type="hidden" name="userurl"   value="} . escapeHTML($userurl) . qq{">};
print qq{<label for="UserName">帳號</label>};
print qq{<input type="text" id="UserName" name="UserName" autocomplete="username" required>};
print qq{<label for="Password">密碼</label>};
print qq{<input type="password" id="Password" name="Password" autocomplete="current-password" required>};
print qq{<button type="submit" class="cp-button">登入</button>};
print qq{</form>};

print html_footer();
exit 0;
