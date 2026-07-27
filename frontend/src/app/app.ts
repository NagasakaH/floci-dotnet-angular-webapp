import { HttpClient, HttpErrorResponse, HttpHeaders } from '@angular/common/http';
import { Component, OnDestroy, OnInit, computed, inject, signal } from '@angular/core';

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

interface StartSearchResponse {
  jobId: string;
  status: SearchJobStatus;
  statusUrl: string;
}

type SearchJobStatus = 'QUEUED' | 'RUNNING' | 'COMPLETED' | 'FAILED';

interface SearchJobResponse {
  jobId: string;
  status: SearchJobStatus;
  query: string;
  createdAt: string;
  updatedAt: string;
  scannedRecords: number;
  resultCount: number;
  downloadUrl?: string;
  downloadExpiresAt?: string;
  error?: string;
}

@Component({
  selector: 'app-root',
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App implements OnInit, OnDestroy {
  private readonly http = inject(HttpClient);
  private searchPollTimer?: ReturnType<typeof setTimeout>;

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
  protected readonly searchQuery = signal('engineering');
  protected readonly searchLoading = signal(false);
  protected readonly searchJob = signal<SearchJobResponse | null>(null);
  protected readonly searchError = signal('');

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

  ngOnDestroy(): void {
    if (this.searchPollTimer) {
      clearTimeout(this.searchPollTimer);
    }
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
    this.searchJob.set(null);
    this.searchError.set('');
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

    const token = this.authenticationToken();
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

  protected startSearch(): void {
    const query = this.searchQuery().trim();
    const token = this.authenticationToken();
    if (!this.apiBaseUrl() || !token) {
      this.searchError.set('API URLまたは認証トークンがありません。');
      return;
    }
    if (query.length < 2) {
      this.searchError.set('検索条件を2文字以上入力してください。');
      return;
    }

    if (this.searchPollTimer) {
      clearTimeout(this.searchPollTimer);
    }
    this.searchLoading.set(true);
    this.searchJob.set(null);
    this.searchError.set('');
    const headers = new HttpHeaders({ Authorization: `Bearer ${token}` });
    this.http
      .post<StartSearchResponse>(
        `${this.apiBaseUrl()}/api/search-jobs`,
        { query, maxResults: 250 },
        { headers },
      )
      .subscribe({
        next: (response) => {
          this.searchJob.set({
            jobId: response.jobId,
            status: response.status,
            query,
            createdAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
            scannedRecords: 0,
            resultCount: 0,
          });
          this.pollSearch(response.jobId, headers);
        },
        error: (error: HttpErrorResponse) => {
          this.searchLoading.set(false);
          this.searchError.set(
            error.status === 401 || error.status === 403
              ? 'このユーザーには非同期検索を実行する権限がありません。'
              : `検索ジョブを開始できませんでした: ${error.message}`,
          );
        },
      });
  }

  private pollSearch(jobId: string, headers: HttpHeaders): void {
    this.searchPollTimer = setTimeout(() => {
      this.http
        .get<SearchJobResponse>(`${this.apiBaseUrl()}/api/search-jobs/${jobId}`, { headers })
        .subscribe({
          next: (job) => {
            this.searchJob.set(job);
            if (job.status === 'QUEUED' || job.status === 'RUNNING') {
              this.pollSearch(jobId, headers);
              return;
            }
            this.searchLoading.set(false);
            if (job.status === 'FAILED') {
              this.searchError.set(job.error ?? '検索処理が失敗しました。');
            }
          },
          error: (error: HttpErrorResponse) => {
            this.searchLoading.set(false);
            this.searchError.set(`検索状態を取得できませんでした: ${error.message}`);
          },
        });
    }, 800);
  }

  private authenticationToken(): string | undefined {
    return this.isAws()
      ? this.authSession()?.accessToken
      : `local:${this.selectedUser().id}`;
  }
}
