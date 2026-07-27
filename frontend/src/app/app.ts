import { HttpClient, HttpErrorResponse, HttpHeaders } from '@angular/common/http';
import { Component, OnInit, computed, inject, signal } from '@angular/core';

interface RuntimeConfig {
  apiBaseUrl: string;
}

interface DemoUser {
  id: string;
  name: string;
  initials: string;
  department: string;
  permissionSource: string;
  expected: 'allow' | 'deny';
}

interface HelloResponse {
  message: string;
  user: string;
}

interface AuthSession {
  accessToken: string;
  expiresAt: number;
  username: string;
  groups: string[];
}

@Component({
  selector: 'app-root',
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App implements OnInit {
  private readonly http = inject(HttpClient);

  protected readonly users: DemoUser[] = [
    { id: 'user-001', name: 'Alice', initials: 'AL', department: 'Engineering', permissionSource: '開発者グループ', expected: 'allow' },
    { id: 'user-003', name: 'Carol', initials: 'CA', department: 'Operations', permissionSource: 'ユーザー個別権限', expected: 'allow' },
    { id: 'user-002', name: 'Bob', initials: 'BO', department: 'Sales', permissionSource: '権限なし', expected: 'deny' },
  ];

  protected readonly selectedUserId = signal(this.users[0].id);
  protected readonly selectedUser = computed(
    () => this.users.find((user) => user.id === this.selectedUserId()) ?? this.users[0],
  );
  protected readonly apiBaseUrl = signal('');
  protected readonly authSession = signal<AuthSession | null>(null);
  protected readonly isAws = computed(
    () => this.apiBaseUrl() !== '' && !this.apiBaseUrl().includes('localhost'),
  );
  protected readonly environmentLabel = computed(() =>
    this.isAws() ? 'AWS development' : 'Local development',
  );
  protected readonly loading = signal(false);
  protected readonly authLoading = signal(false);
  protected readonly result = signal<HelloResponse | null>(null);
  protected readonly errorMessage = signal('');
  protected readonly httpStatus = signal<number | null>(null);

  ngOnInit(): void {
    this.http.get<RuntimeConfig>('/config.json').subscribe({
      next: (config) => {
        this.apiBaseUrl.set(config.apiBaseUrl.replace(/\/$/, ''));
        if (this.isAws()) {
          this.loadAwsSession();
        }
      },
      error: () => this.errorMessage.set('config.json を読み込めませんでした。'),
    });
  }

  private loadAwsSession(): void {
    this.authLoading.set(true);
    this.http.get<AuthSession>('/auth/token').subscribe({
      next: (session) => {
        this.authSession.set(session);
        this.authLoading.set(false);
      },
      error: () => {
        this.errorMessage.set('ログイン情報を取得できませんでした。再ログインしてください。');
        this.authLoading.set(false);
      },
    });
  }

  protected selectUser(userId: string): void {
    this.selectedUserId.set(userId);
    this.result.set(null);
    this.errorMessage.set('');
    this.httpStatus.set(null);
  }

  protected callHelloApi(): void {
    if (!this.apiBaseUrl()) {
      this.errorMessage.set('API URLが未設定です。');
      return;
    }

    this.loading.set(true);
    this.result.set(null);
    this.errorMessage.set('');
    this.httpStatus.set(null);

    const token = this.isAws()
      ? this.authSession()?.accessToken
      : `local:${this.selectedUser().id}`;
    if (!token) {
      this.errorMessage.set('認証トークンがありません。再ログインしてください。');
      this.loading.set(false);
      return;
    }
    const headers = new HttpHeaders({ Authorization: `Bearer ${token}` });

    this.http
      .get<HelloResponse>(`${this.apiBaseUrl()}/api/hello`, { headers, observe: 'response' })
      .subscribe({
        next: (response) => {
          this.httpStatus.set(response.status);
          this.result.set(response.body);
          this.loading.set(false);
        },
        error: (error: HttpErrorResponse) => {
          this.httpStatus.set(error.status);
          this.errorMessage.set(
            error.status === 401 || error.status === 403
              ? 'Authorizerがこのユーザーのアクセスを拒否しました。'
              : `API呼び出しに失敗しました: ${error.message}`,
          );
          this.loading.set(false);
        },
      });
  }
}
