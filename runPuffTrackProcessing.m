%runPuffTrackProcessing(data, varargin) processes the track structure generated by runTracking()
%
% Inputs
%              data : list of movies, using the structure returned by loadConditionData.m
%
% Options
%          'Buffer' : Length of buffer readout before/after each track. Default: [5 5]
%       'Overwrite' : true|{false}. Overwrite previous processing result.
%          'Frames' : Index array of frames if runTracking was called on a subset of frames.
%      'Preprocess' : Perform preprocessing: discard single-frame tracks and decouple
%                       simple compound tracks. Default: true
%     'Postprocess' : Perform postprocessing: validation of tracks based on gap and
%                       buffer intensities; splitting of erroneously linked trajectories.
%                       Default: true
%  'ForceDiffractionLimited' : Treat only diffraction-limited signals as valid tracks.
%                              This is determined via a normality test on the residuals
%                              of the PSF fit.
%
% Example: runPuffTrackProcessing(data, 'Buffer', 3);
%
% Notes: The buffer size influences the number of visible tracks. For a buffer size of
%        5 frames, only tracks initiating in frame 6 are treated as valid.

% Tiffany Phan & Zach Weinberg (2015)

function runPuffTrackProcessing(data, varargin)

ip = inputParser;
ip.CaseSensitive = false;
ip.addRequired('data', @isstruct);
%ip.addParamValue('Buffer', [5 5], @(x) numel(x)==2)
ip.addParamValue('Buffer', [3 3], @(x) numel(x)==2); %(TP***): Changed buffer to 1 to account for shorter puff lengths
ip.addParamValue('BufferAll', false, @islogical);
ip.addParamValue('Overwrite', false, @islogical);
ip.addParamValue('TrackerOutput', 'trackedFeatures.mat', @ischar);
ip.addParamValue('FileName', 'ProcessedTracks.mat', @ischar);
ip.addParameter('DetectionFile', 'detection_v2.mat', @ischar);
ip.addParamValue('Frames', arrayfun(@(x) 1:x.movieLength, data, 'UniformOutput', false), @(x) numel(unique(diff(x)))==1); %check that frame rate is constant
ip.addParamValue('Preprocess', true, @islogical);
ip.addParamValue('Postprocess', true, @islogical);
ip.addParameter('CohortBounds_s', [50 100 150 200 250 300 350 400 500 1000]); % used in post-proc
ip.addParamValue('ForceDiffractionLimited', true, @islogical);
ip.parse(data, varargin{:});
overwrite = ip.Results.Overwrite;
frameIdx = ip.Results.Frames;
if ~iscell(frameIdx)
    frameIdx = {frameIdx};
end

parfor i = 1:length(data)
    if ~(exist([data(i).source filesep 'Tracking' filesep ip.Results.FileName],'file')==2) || overwrite %#ok<PFBNS>
        data(i) = main(data(i), frameIdx{i}, ip.Results);
    else
        fprintf('Tracks from %s have already been processed.\n', getShortPath(data(i)));
    end
end

function [data] = main(data, frameIdx, opts)
preprocess = opts.Preprocess;
postprocess = opts.Postprocess;
cohortBounds = opts.CohortBounds_s;


cutoff_f = 2; % ignore single-frame tracks
minLft = cutoff_f*data.framerate;
cohortBounds(cohortBounds<=minLft) = [];
cohortBounds = [minLft cohortBounds data.movieLength*data.framerate];

dfile = [data.source 'Detection' filesep opts.DetectionFile];
if exist(dfile, 'file')==2
    detection = load([data.source 'Detection' filesep 'detection_v2.mat']);
else
    fprintf('runPuffTrackProcessing: no detection data found for %s\n', getShortPath(data));
    return;
end
frameInfo = detection.frameInfo;
% Sets lowest number of detectable pixels a point source can take up
sigmaV = frameInfo(1).s;


ny = data.imagesize(1);
nx = data.imagesize(2);
nFrames = length(frameIdx);

alpha = 0.05;
kLevel = norminv(1-alpha/2.0, 0, 1); % ~2 std above background

%=================================
% Identify master/slave channels
%=================================
nCh = length(data.channels);

% This checks to see which of the channels is the 'primary' channel
% Primary = the first channel passed to loadConditionData
mCh = strcmp(data.source, data.channels);

% for k = 1:nCh
%     data.framePaths{k} = data.framePaths{k}(frameIdx);
% end
%
% data.maskPaths = data.maskPaths(frameIdx);
% data.framerate = data.framerate*(frameIdx(2)-frameIdx(1));
% data.movieLength = length(data.framePaths{1});


% Setup pit detection radius. Create windows around point source (w3, w4)
sigma = sigmaV(mCh);
% w2 = ceil(2*sigma);
w3 = ceil(3*sigma);
w4 = ceil(4*sigma);

% Creates a circular mask within a grid designated by w4, which is going to be used for pit detection
% Used for gap detection later (passed to interpTrack)
[x,y] = meshgrid(-w4:w4);
r = sqrt(x.^2+y.^2);
annularMask = zeros(size(r));
annularMask(r<=w4 & r>=w3) = 1;

%======================================================================
% Read and convert tracker output
%======================================================================
tPath = [data.source 'Tracking' filesep opts.TrackerOutput];
if exist(tPath, 'file')==2
    trackinfo = load(tPath);
    trackinfo = trackinfo.tracksFinal;
    nTracks = length(trackinfo);
else
    fprintf('runPuffTrackProcessing: no tracking data found for %s\n', getShortPath(data));
    return;
end


%======================================================================
% Preprocessing
%======================================================================
if preprocess
    % Remove single-frame tracks
    bounds = arrayfun(@(i) i.seqOfEvents([1 end],1), trackinfo, 'UniformOutput', false);
    rmIdx = diff(horzcat(bounds{:}), [], 1)==0;
    trackinfo(rmIdx) = [];
    nTracks = size(trackinfo, 1);

end % preprocess
%======================================================================

% Set up track structure
tracks(1:nTracks) = struct('t', [], 'f', [],...
    'x', [], 'y', [], 'A', [], 'maxA', [],...
    'c',[], 'a_norm', [],...
    'Ac', [], 'maxAc',[], 'Ac_norm', [],...
    'x_pstd', [], 'y_pstd', [], 'A_pstd', [], 'c_pstd', [],...
    'sigma_r', [], 'SE_sigma_r', [],...
    'isPSF', [],'visibility', [], 'lifetime_s', [], 'start', [], 'end', [],...
    'startBuffer', [], 'endBuffer', [], 'MotionAnalysis', [],...
    'maskN',[], 'mask_Ar',[],...
    'riseR2', [], 'pfallR2', [], 'pvp', [],...
    'pallAcdiff',[], 'diff', [],...
    'npeaks', [], 'tnpeaks', [],...
    'isPuff', [0]);
    %(TP):
    % meanc_fall and _rise are the average background intensities for the fall and rise portions
    % a_norm is the intensity normalized to background
    % rise_v and fall_v = velocities
    % cfcr = max background in the fall / max background in the rise
    % aaf = min intensity in the fall/maxA
    % atoc = cfcr/aaf, how much of the rise in background is due to decrease in intensity
    % isPuff-> 0 = maybe, 1 = puff, 2 = nonpuff

% track field names
idx = structfun(@(i) size(i,2)==size(frameInfo(1).x,2), frameInfo(1));
mcFieldNames = fieldnames(frameInfo);
[~,loc] = ismember({'s', 'x_init', 'y_init', 'xCoord', 'yCoord', 'amp', 'dRange'}, mcFieldNames);
idx(loc(loc~=0)) = false;
mcFieldNames = mcFieldNames(idx);
mcFieldSizes = structfun(@(i) size(i,1), frameInfo(1));
mcFieldSizes = mcFieldSizes(idx);
bufferFieldNames = {'t', 'x', 'y', 'A', 'c', 'A_pstd', 'c_pstd', 'sigma_r', 'SE_sigma_r', 'pval_Ar'};

%==============================
% Loop through tracks
%==============================
buffer = repmat(opts.Buffer, [nTracks,1]);

fprintf('Processing tracks (%s) - converting tracker output:     ', getShortPath(data));
for k = 1:nTracks

    % convert/assign structure fields
    seqOfEvents = trackinfo(k).seqOfEvents;
    tracksFeatIndxCG = trackinfo(k).tracksFeatIndxCG; % index of the feature in each frame
    nSeg = size(tracksFeatIndxCG,1);

    segLengths = NaN(1,nSeg);

    % Remove short merging/splitting branches
    msIdx = NaN(1,nSeg);
    for s = 1:nSeg
        idx = seqOfEvents(:,3)==s;
        ievents = seqOfEvents(idx, :);
        bounds = ievents(:,1); % beginning & end of this segment
        if ~isnan(ievents(2,4))
            bounds(2) = bounds(2)-1; % correction if end is a merge
        end
        segLengths(s) = bounds(2)-bounds(1)+1;

        % remove short (<4 frames) merging/splitting branches if:
        % -the segment length is a single frame
        % -the segment is splitting and merging from/to the same parent
        % -short segment merges, segment starts after track start
        % -short segment splits, segment ends before track end - (ZYW) Why?
        msIdx(s) = segLengths(s)==1 || (segLengths(s)<4 && ( diff(ievents(:,4))==0 ||...
            (isnan(ievents(1,4)) && ~isnan(ievents(2,4)) && ievents(1,1)>seqOfEvents(1,1)) ||...
            (isnan(ievents(2,4)) && ~isnan(ievents(1,4)) && ievents(2,1)<seqOfEvents(end,1)) ));
    end
    if preprocess && nSeg>1
        segIdx = find(msIdx==0); % index segments to retain (avoids re-indexing segments)
        nSeg = numel(segIdx); % update segment #
        msIdx = find(msIdx);
        if ~isempty(msIdx)
            tracksFeatIndxCG(msIdx,:) = [];
            seqOfEvents(ismember(seqOfEvents(:,3), msIdx),:) = [];
        end
        segLengths = segLengths(segIdx);
    else
        segIdx = 1:nSeg;
    end

    tracks(k).nSeg = nSeg;
    firstIdx = trackinfo(k).seqOfEvents(1,1);
    lastIdx = trackinfo(k).seqOfEvents(end,1);

    tracks(k).lifetime_s = (lastIdx-firstIdx+1)*data.framerate;
    tracks(k).start = firstIdx;
    tracks(k).end = lastIdx;

    tracks(k).seqOfEvents = seqOfEvents;
    tracks(k).tracksFeatIndxCG = tracksFeatIndxCG; % index of the feature in each frame

    if (buffer(k,1)<tracks(k).start) && (tracks(k).end<=nFrames-buffer(k,2)) % complete tracks
        tracks(k).visibility = 1;
    elseif tracks(k).start==1 && tracks(k).end==nFrames % persistent tracks
        tracks(k).visibility = 3;
    else
        tracks(k).visibility = 2; % incomplete tracks
    end

    %==============================================================================
    % Initialize arrays
    %==============================================================================

    % Segments are concatenated into single arrays, separated by NaNs.
    fieldLength = sum(segLengths)+nSeg-1;
    for f = 1:length(mcFieldNames)
        tracks(k).(mcFieldNames{f}) = NaN(mcFieldSizes(f), fieldLength);
    end
    tracks(k).t = NaN(1, fieldLength);
    tracks(k).f = NaN(1, fieldLength);

    if fieldLength>1

        % start buffer size for this track
        sb = firstIdx - max(1, firstIdx-buffer(k,1));
        eb = min(lastIdx+buffer(k,2), data.movieLength)-lastIdx;
        if sb>0 && (tracks(k).visibility==1 || opts.BufferAll)
            for f = 1:length(bufferFieldNames)
                tracks(k).startBuffer.(bufferFieldNames{f}) = NaN(nCh, sb);
            end
        end
        if eb>0 && (tracks(k).visibility==1 || opts.BufferAll)
            for f = 1:length(bufferFieldNames)
                tracks(k).endBuffer.(bufferFieldNames{f}) = NaN(nCh, eb);
            end
        end
    end

    %==============================================================================
    % Read amplitude & background from detectionResults.mat (localization results)
    %==============================================================================
    delta = [0 cumsum(segLengths(1:end-1))+(1:nSeg-1)];

    for s = 1:nSeg
        ievents = seqOfEvents(seqOfEvents(:,3)==segIdx(s), :);
        bounds = ievents(:,1);
        if ~isnan(ievents(2,4))
            bounds(2) = bounds(2)-1;
        end

        nf = bounds(2)-bounds(1)+1;
        frameRange = frameIdx(bounds(1):bounds(2)); % relative to movie (also when movie is subsampled)

        for i = 1:length(frameRange)
            idx = tracksFeatIndxCG(s, frameRange(i) - tracks(k).start + 1); % -> relative to IndxCG
            if idx ~= 0 % if not a gap, get detection values
                for f = 1:length(mcFieldNames)
                    tracks(k).(mcFieldNames{f})(:,i+delta(s)) = frameInfo(frameRange(i)).(mcFieldNames{f})(:,idx);
                end
            end
        end
        tracks(k).t(delta(s)+(1:nf)) = (bounds(1)-1:bounds(2)-1)*data.framerate;
        tracks(k).f(delta(s)+(1:nf)) = frameRange;
    end

    fprintf('\b\b\b\b%3d%%', round(100*k/nTracks));
end
fprintf('\n');

%(TP)Remove all tracks with lifetime < 0.4
rmlt= find([tracks.lifetime_s]<0.4);
tracks(rmlt) = [];
buffer(rmlt,:) = [];

%(ZYW) Remove all tracks that start in first frame and have peak amplitude
% in first frame of track.
% rmft = [];
% for i=1:numel(tracks)
%   ampl = tracks(i).A + tracks(i).c;
%   if tracks(i).start == 1
%     [~, ii] = max(ampl);
%     if ii == 1
%       rmft = [rmft i];
%     end
%   end
% end
% tracks(rmft) = [];
% buffer(rmft,:) = [];

% remove tracks that fall into image boundary
minx = round(arrayfun(@(t) min(t.x(:)), tracks));
maxx = round(arrayfun(@(t) max(t.x(:)), tracks));
miny = round(arrayfun(@(t) min(t.y(:)), tracks));
maxy = round(arrayfun(@(t) max(t.y(:)), tracks));

idx = minx<=w4 | miny<=w4 | maxx>nx-w4 | maxy>ny-w4;
tracks(idx) = [];
buffer(idx,:) = [];
nTracks = numel(tracks);

%=======================================
% Interpolate gaps and clean up tracks
%=======================================
fprintf('Processing tracks (%s) - classification:     ', getShortPath(data));
for k = 1:nTracks

    %gap locations in 'x' for all segments
    gapVect = isnan(tracks(k).x(mCh,:)) & ~isnan(tracks(k).t);
    tracks(k).gapVect = gapVect;

%     =================================
%     Determine track and gap status
%     =================================
    sepIdx = isnan(tracks(k).t);

    gapCombIdx = diff(gapVect | sepIdx);
    gapStarts = find(gapCombIdx==1)+1;
    gapEnds = find(gapCombIdx==-1);
    gapLengths = gapEnds-gapStarts+1;

    segmentIdx = diff([0 ~(gapVect | sepIdx) 0]); % these variables refer to segments between gaps
    segmentStarts = find(segmentIdx==1);
    segmentEnds = find(segmentIdx==-1)-1;
    segmentLengths = segmentEnds-segmentStarts+1;

%     loop over gaps
    nGaps = numel(gapLengths);
    if nGaps>0
        gv = 1:nGaps;
        gapStatus = 5*ones(1,nGaps);
%         gap valid if segments that precede/follow are > 1 frame or if gap is a single frame
        gapStatus(segmentLengths(gv)>1 & segmentLengths(gv+1)>1 | gapLengths(gv)==1) = 4;

        sepIdx = sepIdx(gapStarts)==1;
        gapStatus(sepIdx) = [];
        gapStarts(sepIdx) = [];
        gapEnds(sepIdx) = [];
        nGaps = numel(gapStatus);

%         fill position information for valid gaps using linear interpolation
        for g = 1:nGaps
            borderIdx = [gapStarts(g)-1 gapEnds(g)+1];
            gacombIdx = gapStarts(g):gapEnds(g);
            for c = 1:nCh
                tracks(k).x(c, gacombIdx) = interp1(borderIdx, tracks(k).x(c, borderIdx), gacombIdx);
                tracks(k).y(c, gacombIdx) = interp1(borderIdx, tracks(k).y(c, borderIdx), gacombIdx);
            end
        end
        tracks(k).gapStatus = gapStatus;
        tracks(k).gapIdx = arrayfun(@(i) gapStarts(i):gapEnds(i), 1:nGaps, 'UniformOutput', false);
    end
    fprintf('\b\b\b\b%3d%%', round(100*k/nTracks));
end
fprintf('\n');

%====================================================================================
% Generate buffers before and after track, estimate gap values
%====================================================================================
% Gap map for fast indexing
gapMap = zeros(nTracks, data.movieLength);
for k = 1:nTracks
    gapMap(k, tracks(k).f(tracks(k).gapVect==1)) = 1;
end

% for buffers:
trackStarts = [tracks.start];
trackEnds = [tracks.end];
fullTracks = [tracks.visibility]==1 | (opts.BufferAll & [tracks.visibility]==2);

fprintf('Processing tracks (%s) - gap interpolation, buffer readout:     ', getShortPath(data));
for f = 1:data.movieLength
    if iscell(data.framePaths{mCh})
        mask = double(imread(data.maskPaths{f}));
    else
        mask = double(readtiff(data.maskPaths, f));
    end

    % binarize
    mask(mask~=0) = 1;
    labels = bwlabel(mask);

    for ch = 1:nCh
        if iscell(data.framePaths{mCh})
            frame = double(imread(data.framePaths{ch}{f}));
        else
            frame = double(readtiff(data.framePaths{ch}, f));
        end

        %------------------------
        % Gaps
        %------------------------
        % tracks with valid gaps visible in current frame
        currentGapsIdx = find(gapMap(:,f));
        for ki = 1:numel(currentGapsIdx)
            k = currentGapsIdx(ki);

            % index in the track structure (.x etc)
            idxList = find(tracks(k).f==f & tracks(k).gapVect==1);

            for l = 1:numel(idxList)
                idx = idxList(l);
                [t0] = interpTrack(tracks(k).x(ch,idx), tracks(k).y(ch,idx), frame, labels, annularMask, sigma, sigmaV(ch), kLevel);
                tracks(k) = mergeStructs(tracks(k), ch, idx, t0);
            end
        end

        %------------------------
        % start buffer
        %------------------------
        % tracks with start buffers in this frame
        cand = max(1, trackStarts-buffer(:,1)')<=f & f<trackStarts;
        % corresponding tracks, only if status = 1
        currentBufferIdx = find(cand & fullTracks);

        for ki = 1:length(currentBufferIdx)
            k = currentBufferIdx(ki);

            [t0] = interpTrack(tracks(k).x(ch,1), tracks(k).y(ch,1), frame, labels, annularMask, sigma, sigmaV(ch), kLevel);
            bi = f - max(1, tracks(k).start-buffer(k,1)) + 1;
            tracks(k).startBuffer = mergeStructs(tracks(k).startBuffer, ch, bi, t0);
        end

        %------------------------
        % end buffer
        %------------------------
        % segments with end buffers in this frame
        cand = trackEnds<f & f<=min(data.movieLength, trackEnds+buffer(:,2)');
        % corresponding tracks
        currentBufferIdx = find(cand & fullTracks);

        for ki = 1:length(currentBufferIdx)
            k = currentBufferIdx(ki);

            [t0] = interpTrack(tracks(k).x(ch,end), tracks(k).y(ch,end), frame, labels, annularMask, sigma, sigmaV(ch), kLevel);
            bi = f - tracks(k).end;
            tracks(k).endBuffer = mergeStructs(tracks(k).endBuffer, ch, bi, t0);
        end
        fprintf('\b\b\b\b%3d%%', round(100*(ch + (f-1)*nCh)/(nCh*data.movieLength)));
    end
end
fprintf('\n');

%----------------------------------
% Add time vectors to buffers
%----------------------------------
for k = 1:nTracks
    % add buffer time vectors
    if ~isempty(tracks(k).startBuffer)
        b = size(tracks(k).startBuffer.x,2);
        tracks(k).startBuffer.t = ((-b:-1) + tracks(k).start-1) * data.framerate;
    end
    if ~isempty(tracks(k).endBuffer)
        b = size(tracks(k).endBuffer.x,2);
        tracks(k).endBuffer.t = (tracks(k).end + (1:b)-1) * data.framerate;
    end
end


%============================================================================
% Run post-processing
%============================================================================
if postprocess
    %----------------------------------------------------------------------------
    % I. Assign category to each track
    %----------------------------------------------------------------------------
    % Categories:
    % Ia)  Single tracks with valid gaps
    % Ib)  Single tracks with invalid gaps
    % Ic)  Single tracks cut at beginning or end
    % Id)  Single tracks, persistent
    % IIa) Compound tracks with valid gaps
    % IIb) Compound tracks with invalid gaps
    % IIc) Compound tracks cut at beginning or end
    % IId) Compound tracks, persistent

    % The categories correspond to index 1-8, in the above order

    validGaps = arrayfun(@(t) max([t.gapStatus 4]), tracks)==4;
    singleIdx = [tracks.nSeg]==1;
    vis = [tracks.visibility];

    mask_Ia = singleIdx & validGaps & vis==1;
    mask_Ib = singleIdx & ~validGaps & vis==1;
    idx_Ia = find(mask_Ia);
    idx_Ib = find(mask_Ib);
    trackLengths = [tracks.end]-[tracks.start]+1;

    C = [mask_Ia;
        2*mask_Ib;
        3*(singleIdx & vis==2); % this should b3
        4*(singleIdx & vis==3);
        5*(~singleIdx & validGaps & vis==1);
        6*(~singleIdx & ~validGaps & vis==1);
        7*(~singleIdx & vis==2); % this should be 7
        8*(~singleIdx & vis==3)];

    C = num2cell(sum(C,1));
    % assign category
    [tracks.catIdx] = deal(C{:});

    %----------------------------------------------------------------------------
    % II. Identify diffraction-limited tracks (CCPs)
    %----------------------------------------------------------------------------
    % Criterion: if all detected points pass AD-test, then track is a CCP.
    % (gaps in the track are not considered in this test)

    % # diffraction-limited points per track (can be different from track length for compound tracks!)
    nPl = arrayfun(@(i) nansum(i.hval_AD(mCh,:) .* ~i.gapVect), tracks);
    isCCP = num2cell(nPl==0);
    [tracks.isCCP] = deal(isCCP{:});
    isCCP = [isCCP{:}];

    % average mask area per track
    % meanMaskAreaCCP = arrayfun(@(i) nanmean(i.maskN), tracks(isCCP));
    % meanMaskAreaNotCCP = arrayfun(@(i) nanmean(i.maskN), tracks(~isCCP));

    %----------------------------------------------------------------------------
    % III. Process 'Ib' tracks:
    %----------------------------------------------------------------------------
    % Reference distribution: class Ia tracks
    % Determine critical max. intensity values from class Ia tracks, per lifetime cohort

    % # cohorts
    nc = numel(cohortBounds)-1;

    % max intensities of all 'Ia' tracks
    maxInt = arrayfun(@(i) max(i.A(mCh,:)), tracks(idx_Ia));
    maxIntDistr = cell(1,nc);
    mappingThresholdMaxInt = zeros(1,nc);
    lft_Ia = [tracks(idx_Ia).lifetime_s];
    for i = 1:nc
        maxIntDistr{i} = maxInt(cohortBounds(i)<=lft_Ia & lft_Ia<cohortBounds(i+1));
        % critical values for test
        mappingThresholdMaxInt(i) = prctile(maxIntDistr{i}, 2.5);
    end

    % get lifetime histograms before change
    processingInfo.lftHists.before = getLifetimeHistogram(data, tracks);

    % Criteria for mapping:
    % - max intensity must be within 2.5th percentile of max. intensity distribution for 'Ia' tracks
    % - lifetime >= 5 frames (at 4 frames: track = [x o o x])

    % assign category I to tracks that match criteria
    for k = 1:numel(idx_Ib);
        i = idx_Ib(k);

        % get cohort idx for this track (logical)
        cIdx = cohortBounds(1:nc)<=tracks(i).lifetime_s & tracks(i).lifetime_s<cohortBounds(2:nc+1);

        if max(tracks(i).A(mCh,:)) >= mappingThresholdMaxInt(cIdx) && trackLengths(i)>4
            tracks(i).catIdx = 1;
        end
    end
    processingInfo.lftHists.after = getLifetimeHistogram(data, tracks);

    %----------------------------------------------------------------------------
    % IV. Apply threshold on buffer intensities
    %----------------------------------------------------------------------------
    % Conditions:
    % - the amplitude in at least 2 consecutive frames must be within background in each buffer
    % - the maximum buffer amplitude must be smaller than the maximum track amplitude

    Tbuffer = 2;

    % loop through cat. Ia tracks
    idx_Ia = find([tracks.catIdx]==1);
    for k = 1:numel(idx_Ia)
        i = idx_Ia(k);

        if ~isempty(tracks(i).startBuffer) && ~isempty(tracks(i).endBuffer)
            % H0: A = background (p-value >= 0.05)
            sbin = tracks(i).startBuffer.pval_Ar(mCh,:) < 0.05; % positions with signif. signal
            ebin = tracks(i).endBuffer.pval_Ar(mCh,:) < 0.05;
            [sl, sv] = binarySegmentLengths(sbin);
            [el, ev] = binarySegmentLengths(ebin);
            if ~any(sl(sv==0)>=Tbuffer) || ~any(el(ev==0)>=Tbuffer) ||...
                    max([tracks(i).startBuffer.A(mCh,:)+tracks(i).startBuffer.c(mCh,:)...
                    tracks(i).endBuffer.A(mCh,:)+tracks(i).endBuffer.c(mCh,:)]) >...
                    max(tracks(i).A(mCh,:)+tracks(i).c(mCh,:))
                tracks(i).catIdx = 2;
            end
        end
    end

    %----------------------------------------------------------------------------
    % V. Assign Cat. Ib to tracks that are not diffraction-limited CCPs
    %----------------------------------------------------------------------------
    if opts.ForceDiffractionLimited
        [tracks([tracks.catIdx]==1 & ~isCCP).catIdx] = deal(2);
    end

    %----------------------------------------------------------------------------
    % VI. Cut tracks with sequential events (hotspots) into individual tracks
    %----------------------------------------------------------------------------
    %splitCand = find([tracks.catIdx]==1 & arrayfun(@(i) ~isempty(i.gapIdx), tracks) & trackLengths>4);
    splitCand = find([tracks.catIdx]==1 & arrayfun(@(i) ~isempty(i.gapIdx), tracks) & trackLengths>2); %(TP***) at least 0.2s/puff
    % Loop through tracks and test whether gaps are at background intensity
    rmIdx = []; % tracks to remove from list after splitting
    newTracks = [];
    for i = 1:numel(splitCand);
        k = splitCand(i);

        % all gaps
        gapIdx = [tracks(k).gapIdx{:}];

        % # residual points
        npx = round((tracks(k).sigma_r(mCh,:) ./ tracks(k).SE_sigma_r(mCh,:)).^2/2+1);
        npx = npx(gapIdx);

        % t-test on gap amplitude
        A = tracks(k).A(mCh, gapIdx);
        sigma_A = tracks(k).A_pstd(mCh, gapIdx);
        T = (A-sigma_A)./(sigma_A./sqrt(npx));
        pval = tcdf(T, npx-1);

        % gaps with signal below background level: candidates for splitting
        splitIdx = pval<0.05;
        gapIdx = gapIdx(splitIdx==1);

        % new segments must be at least 5 frames
        delta = diff([1 gapIdx trackLengths(k)]); % (TP) gives the number of frames of segment from start of track to gap and segment from gap to end of track
        %gapIdx(delta(1:end-1)<5 | delta(2:end)<5) = [];
        gapIdx(delta(1:end-1)<2 | delta(2:end)<2) = []; % (TP***): new segs need to be at least 0.2s

        ng = numel(gapIdx);
        splitIdx = zeros(1,ng);

        for g = 1:ng

            % split track at gap position
            % {ZYW & TP} Using median here picks the coordinates from the middle /frame/, not the average X,Y coords
            x1 = tracks(k).x(mCh, 1:gapIdx(g)-1);
            y1 = tracks(k).y(mCh, 1:gapIdx(g)-1);
            x2 = tracks(k).x(mCh, gapIdx(g)+1:end);
            y2 = tracks(k).y(mCh, gapIdx(g)+1:end);
            mux1 = median(x1);
            muy1 = median(y1);
            mux2 = median(x2);
            muy2 = median(y2);

            % projections
            v = [mux2-mux1; muy2-muy1];
            v = v/norm(v);

            % (ZYW & TP) sp below is total movement of spot before and after gap
            % sp = summed projection

            % x1 in mux1 reference
            X1 = [x1-mux1; y1-muy1];
            sp1 = sum(repmat(v, [1 numel(x1)]).*X1,1);

            % x2 in mux1 reference
            X2 = [x2-mux1; y2-muy1];
            sp2 = sum(repmat(v, [1 numel(x2)]).*X2,1);

            % test whether projections are distinct distributions of points
            % may need to be replaced by outlier-robust version
            % (ZYW) IS THERE A BETTER WAY TO TEST THIS???
            if mean(sp1)<mean(sp2) && prctile(sp1,95)<prctile(sp2,5)
                splitIdx(g) = 1;
            elseif mean(sp1)>mean(sp2) && prctile(sp1,5)>prctile(sp2,95)
                splitIdx(g) = 1;
            else
                splitIdx(g) = 0;
            end
        end
        gapIdx = gapIdx(splitIdx==1);

        if ~isempty(gapIdx)
            % store index of parent track, to be removed at end
            rmIdx = [rmIdx k]; %#ok<AGROW>

            % new tracks
            splitTracks = cutTrack(tracks(k), gapIdx);
            newTracks = [newTracks splitTracks]; %#ok<AGROW>
        end
    end
    % final assignment
    % fprintf('# tracks cut: %d\n', numel(rmIdx));
    tracks(rmIdx) = [];
    tracks = [tracks newTracks];

    % remove tracks with more gaps than frames
    nGaps = arrayfun(@(i) sum(i.gapVect), tracks);
    trackLengths = [tracks.end]-[tracks.start]+1;

    % fprintf('# tracks with >50%% gaps: %d\n', sum(nGaps./trackLengths>=0.5));
    [tracks(nGaps./trackLengths>=0.5).catIdx] = deal(2);


    % Displacement statistics: remove tracks with >4 large frame-to-frame displacements
    nt = numel(tracks);
    dists = cell(1,nt);
    medianDist = zeros(1,nt);
    for i = 1:nt
        dists{i} = sqrt((tracks(i).x(mCh,2:end) - tracks(i).x(mCh,1:end-1)).^2 +...
            (tracks(i).y(mCh,2:end) - tracks(i).y(mCh,1:end-1)).^2);
        medianDist(i) = nanmedian(dists{i});
    end
    p95 = prctile(medianDist, 95);
    for i = 1:nt
        if sum(dists{i}>p95)>4 && tracks(i).catIdx==1
        %if sum(dists{i}>p95)>1 && tracks(i).catIdx==1 %(TP***): remove tracks >1 frame-frame displacement
            tracks(i).catIdx = 2;
        end
    end


%(TP***) assign category 6 to all category 1 tracks with gaps
idx_Ia = find([tracks.catIdx]==1);
for k = 1:numel(idx_Ia)
 if ~isempty(tracks(idx_Ia(k)).gapIdx)
     tracks(idx_Ia(k)).catIdx = 6
 end
end

    %==========================================
    % Compute displacement statistics
    %==========================================
    % Only on valid tracks (Cat. Ia)
    trackIdx = find([tracks.catIdx]<8);
    fprintf('Processing tracks (%s) - calculating statistics:     ', getShortPath(data));
    for ki = 1:numel(trackIdx)
        k = trackIdx(ki);
        x = tracks(k).x(mCh,:);
        y = tracks(k).y(mCh,:);
        tracks(k).MotionAnalysis.totalDisplacement = sqrt((x(end)-x(1))^2 + (y(end)-y(1))^2);
        % calculate MSD
        L = 10;
        msdVect = NaN(1,L);
        msdStdVect = NaN(1,L);
        for l = 1:min(L, numel(x)-1)
            tmp = (x(1+l:end)-x(1:end-l)).^2 + (y(1+l:end)-y(1:end-l)).^2;
            msdVect(l) = mean(tmp);
            msdStdVect(l) = std(tmp);
        end
        tracks(k).MotionAnalysis.MSD = msdVect;
        tracks(k).MotionAnalysis.MSDstd = msdStdVect;
        fprintf('\b\b\b\b%3d%%', round(100*ki/numel(trackIdx)));
    end
    fprintf('\n');

    % (ZYW) Once all categorization has been completed, loop through tracks and calculate Rsquared values
    fprintf('Processing tracks (%s) - fitting attack and decay functions:     ', getShortPath(data));
    for kj = 1:numel(tracks)
        if any(isnan([tracks(kj).A]))
            tracks(kj).A = inpaint_nans([tracks(kj).A]);
        end
        if any(isnan([tracks(kj).c]))
            tracks(kj).c = inpaint_nans([tracks(kj).c]);
        end
        
        %(TP)Curve-fitting rise and fall of tracks
        %[fitted_rise rgof numRise] = riseFit(tracks(kj));
        [fitted_fall fgof numFall] = fallFit(tracks(kj));
        %tracks(kj).riseR2 = rgof.rsquare; %Exp fit R^2 of rise portion
        tracks(kj).pfallR2 = fgof.rsquare; %Power Fit R^2 of fall portion
       
        %(TP)Max intensity and intensity normalized 0-1
        tracks(kj).Ac = [tracks(kj).A] + [tracks(kj).c];
        tracks(kj).maxAc = max([tracks(kj).Ac]);
        tracks(kj).Ac_norm = ([tracks(kj).Ac]-min([tracks(kj).Ac]))/([tracks(kj).maxAc]-min([tracks(kj).Ac]));
        
        %(TP)Calculating pvp (% valid points) 
        [a,~,~,d] = findpeaks(tracks(kj).Ac); 
        tracks(kj).tnpeaks = numel(a);
        p = findpeaks(tracks(kj).Ac, 'MinPeakProminence', mean(d)); 
        tracks(kj).npeaks = numel(p); 
        
        if tracks(kj).npeaks == 1 & tracks(kj).tnpeaks ==1
            tracks(kj).pvp = 0;
        else if tracks(kj).tnpeaks == 0 & tracks(kj).npeaks == 0
            tracks(kj).pvp = -1; 
        else
            tracks(kj).pvp = tracks(kj).npeaks/tracks(kj).tnpeaks;
            end
        end 
        
        %(TP) Calculating diff, to get pallAdiff after 
        tracks(kj).diff = tracks(kj).maxAc - mean([tracks(kj).Ac]); 
        
        %(TP) Mean background intensity for rise and fall
%         tracks(kj).meanc_rise = mean(tracks(kj).c(1:numRise)); %background values for rise portion of track
%         tracks(kj).meanc_fall = mean(tracks(kj).c(numRise:end)); %background values for fall portion of track

        %(TP) Normalized intensity to background and velocities to rise and fall
%         cdiff = tracks(kj).meanc_fall - tracks(kj).meanc_rise; 
        %tracks(kj).a_norm = (tracks(kj).A)/cdiff; %normalized background to intensity 
%         tracks(kj).a_norm = ([tracks(kj).A]-min([tracks(kj).A]))/([tracks(kj).maxA]-min([tracks(kj).A]));
%         cdiff = tracks(kj).meanc_fall - tracks(kj).meanc_rise;
%         tracks(kj).a_norm = (tracks(kj).A)/cdiff; %normalized background to intensity
%         tracks(kj).fall_v = (find(tracks(kj).A(numRise:end)== min(tracks(kj).A(numRise:end))))*0.1; %velocity from peak to lowest point in fall portion
%         risemin = find(tracks(kj).A(1:numRise)== min(tracks(kj).A(1:numRise)));
%         tracks(kj).rise_v = (find(tracks(kj).A == max(tracks(kj).A)) - (risemin))*0.1 ; %velocity from lowest point to peak in rise portion

        %(TP) dependency of rise in background to decrease in intensity
%         tracks(kj).cfcr = max([tracks(kj).c(numRise:end)])- max([tracks(kj).c(1:numRise)]);
%         tracks(kj).aaf = min([tracks(kj).A(numRise:end)]) - tracks(kj).maxA;
%         tracks(kj).atoc = tracks(kj).cfcr/tracks(kj).aaf;

        fprintf('\b\b\b\b%3d%%', round(100*kj/numel(tracks)));
    end
    
    %(TP) Calculating pallAdiff 
    maxdiff = max([tracks.diff]);
    mindiff = min([tracks.diff]); 
    for kj = 1:numel(tracks) 
        tracks(kj).pallAcdiff = ([tracks(kj).diff] - mindiff)/(maxdiff-mindiff);
    end 
    fprintf('\n');
    
    fprintf('Processing for %s complete - valid/total tracks: %d/%d (%.1f%%).\n',...
        getShortPath(data), sum([tracks.catIdx]==1), numel(tracks), sum([tracks.catIdx]==1)/numel(tracks)*100);

end % postprocessing


%==========================================
% Save results
%==========================================
if ~(exist([data.source 'Tracking'], 'dir')==7)
    mkdir([data.source 'Tracking']);
end
if isunix
    cmd = ['svn info ' mfilename('fullpath') '.m | grep "Last Changed Rev"'];
    [status,rev] = system(cmd);
    if status==0
        rev = regexp(rev, '\d+', 'match');
        processingInfo.revision = rev{1};
    end
end
processingInfo.procFlag = [preprocess postprocess];

save([data.source 'Tracking' filesep opts.FileName], 'tracks', 'processingInfo','-v7.3');

% calculate track fields for gap or buffer position
function [ps] = interpTrack(x, y, frame, labels, annularMask, sigma, sigmaCh, kLevel)

xi = round(x);
yi = round(y);

w2 = ceil(2*sigma);
w4 = ceil(4*sigma);
% window/masks (see psfLocalization.m for details)
maskWindow = labels(yi-w4:yi+w4, xi-w4:xi+w4);
maskWindow(maskWindow==maskWindow(w4+1,w4+1)) = 0;

cmask = annularMask;
cmask(maskWindow~=0) = 0;
window = frame(yi-w4:yi+w4, xi-w4:xi+w4);

ci = mean(window(cmask==1));
window(maskWindow~=0) = NaN;

x0 = x-xi;
y0 = y-yi;
npx = sum(isfinite(window(:)));
[prm, prmStd, ~, res] = fitGaussian2D(window, [x0 y0 max(window(:))-ci sigmaCh ci], 'xyAc');
dx = prm(1);
dy = prm(2);
if (dx > -w2 && dx < w2 && dy > -w2 && dy < w2)
    ps.x = xi+dx;
    ps.y = yi+dy;
    ps.A_pstd = prmStd(3);
    ps.c_pstd = prmStd(4);
else
    [prm, prmStd, ~, res] = fitGaussian2D(window, [x0 y0 max(window(:))-ci sigmaCh ci], 'Ac');
    ps.x = x;
    ps.y = y;
    ps.A_pstd = prmStd(1);
    ps.c_pstd = prmStd(2);
end
ps.A = prm(3);
ps.c = prm(5);

ps.sigma_r = res.std;
ps.SE_sigma_r = res.std/sqrt(2*(npx-1));

SE_r = ps.SE_sigma_r * kLevel;

ps.hval_AD = res.hAD;

df2 = (npx-1) * (ps.A_pstd.^2 + SE_r.^2).^2 ./...
    (ps.A_pstd.^4 + SE_r.^4);

scomb = sqrt((ps.A_pstd.^2 + SE_r.^2)/npx);
T = (ps.A - res.std*kLevel) ./ scomb;
ps.pval_Ar = tcdf(-T, df2);


function ps = mergeStructs(ps, ch, idx, cs)

cn = fieldnames(cs);
for f = 1:numel(cn)
    ps.(cn{f})(ch,idx) = cs.(cn{f});
end
