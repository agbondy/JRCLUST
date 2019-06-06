function S = loadMetadata(metafile)
    %LOADMETADATA convert SpikeGLX metadata to struct
    %   TODO: build into Config workflow to cut down on specified parameters

    % get absolute path of metafile
    metafile_ = jrclust.utils.absPath(metafile);
    if isempty(metafile_)
        error('could not find meta file %s', metafile);
    end

    try
        S = jrclust.utils.metaToStruct(metafile_);
    catch ME
        error('could not read meta file %s: %s', metafile, ME.message);
    end

    S.dataType = 'int16'; % whisper standard
    S.adcBits = 16;
    S.probe = '';

    %convert new fields to old fields
    if isfield(S, 'niSampRate') % SpikeGLX
        S.nChans = S.nSavedChans;
        S.sampleRate = S.niSampRate;
        S.rangeMax = S.niAiRangeMax;
        S.rangeMin = S.niAiRangeMin;
        S.gain = S.niMNGain;
        try
            S.outputFile = S.fileName;
            S.sha1 = S.fileSHA1;
            S.probe = 'imec2';
        catch
            S.outputFile = '';
            S.sha1 = [];
        end
    elseif isfield(S, 'imSampRate') % IMECIII
        refChans = [37 76 113 152 189 228 265 304 341 380];
        siteLoc = zeros(384, 2);
        viHalf = 0:191;
        siteLoc(1:2:end,2) = viHalf * 20;
        siteLoc(2:2:end,2) = siteLoc(1:2:end,2);
        siteLoc(1:4:end,1) = 16; % 0 before
        siteLoc(2:4:end,1) = 48; % 32 before
        siteLoc(3:4:end,1) = 0;  % 16 before
        siteLoc(4:4:end,1) = 32; % 48 before

        S.nChans = S.nSavedChans;
        S.sampleRate = S.imSampRate;
        S.rangeMax = S.imAiRangeMax;
        S.rangeMin = S.imAiRangeMin;
        S.adcBits = 10; % 10 bit adc but 16 bit saved

        % read data from ~imroTbl
        imroTbl = strsplit(S.imroTbl(2:end-1), ')(');
        imroTblHeader = cellfun(@str2double, strsplit(imroTbl{1}, ','));
        if numel(imroTblHeader) == 3 % 3A with option
            S.probeOpt = imroTblHeader(2);
            S.probe = sprintf('imec3_opt%d', S.probeOpt);
        else
            S.probe = 'imec3';
        end

        % parse first entry in imroTbl
        imroTblChan = cellfun(@str2double, strsplit(imroTbl{2}, ' '));

        S.gain = imroTblChan(4);
        S.gainLFP = imroTblChan(5);

        % get number of saved AP channels as nSites
        try
            snsChanMap = strsplit(S.snsChanMap(2:end-1), ')(');
            apChans = cellfun(@(x) numel(x) >= 2 && strcmp(x(1:2), 'AP'), snsChanMap);
            apChanMap = snsChanMap(apChans);
            apChanMap = cellfun(@(x) strsplit(x, ':'), apChanMap, 'UniformOutput', 0); % split by :
            apChanMap = cellfun(@(x) str2double(x{2}), apChanMap) + 1; % take zero-based order index

            % get shank map
            snsShankMap = strsplit(S.snsShankMap(2:end-1), ')(');
            snsShankMap = cellfun(@(x) strsplit(x, ':'), snsShankMap(apChans), 'UniformOutput', 0);
            snsShankMap = cellfun(@(x) str2double(x(1)) + 1, snsShankMap);

            S.sites = setdiff(apChanMap, refChans); % sites saved
            S.nSites = numel(S.sites);
            S.siteLoc = siteLoc(S.sites, :);
            S.shankMap = snsShankMap(S.sites);
        catch ME
        end

        S.S_imec3 = [];

        %% commented out below by AGB beucase it relies on HHMI dropbox files lol.
%         try
%             S.S_imec3 = imec3_imroTbl_(S);
%         catch
%             S.S_imec3 = [];
%         end
    end

    %number of bits of ADC [was 16 in Chongxi original]
    try
        S.scale = ((S.rangeMax - S.rangeMin)/(2^S.adcBits))/S.gain * 1e6; %uVolts
    catch
        S.scale = 1;
    end

    S.bitScaling = S.scale;
    if isfield(S, 'gainLFP')
        S.bitScalingLFP = S.scale * S.gain / S.gainLFP;
    end
end

%% LOCALFUNCTIONS
function S_imec3 = imec3_imroTbl_(S)
    % Smeta has imroTbl
    vcDir_probe = 'C:\Dropbox (HHMI)\IMEC\SpikeGLX_Probe_Cal_Data\'; %this may crash. probe calibaration folder

    if isstruct(S)
        S = {S};
    end

    % parse imroTbl
    cs_imroTbl = cellfun(@(S)S.imroTbl, S, 'UniformOutput', 0);
    cvn_imroTbl = cellfun(@(vc)textscan(vc, '%d', 'Delimiter', '( ),'), cs_imroTbl, 'UniformOutput', 0);
    cvn_imroTbl = cellfun(@(c)c{1}, cvn_imroTbl, 'UniformOutput', 0);
    S_imec3.viBank = cellfun(@(vn)vn(7), cvn_imroTbl);
    S_imec3.viRef = cellfun(@(vn)vn(8), cvn_imroTbl);
    S_imec3.vrGain_ap = single(cellfun(@(vn)vn(9), cvn_imroTbl));
    S_imec3.vrGain_lf = single(cellfun(@(vn)vn(10), cvn_imroTbl));
    S_imec3.nSites_bank = cvn_imroTbl{1}(4);

    Smeta1 = S{1};

    % correct gain
    nFiles = numel(S_imec3.viBank);
    nSites = numel(Smeta1.viSites);
    [mrScale_ap, mrScale_lf] = deal(ones(nSites, nFiles));
    S_imec3.vcProbeSN = sprintf('1%d%d', Smeta1.imProbeSN, Smeta1.imProbeOpt);
    % read gain correction
    vrGainCorr = ones(1, S_imec3.nSites_bank*4);
    if Smeta1.imProbeOpt ~= 2
        try
            vcFile_csv = sprintf('%s1%d%d\\Gain correction.csv', vcDir_probe, Smeta1.imProbeSN, Smeta1.imProbeOpt);
            try
                vrGainCorr = csvread(vcFile_csv, 1, 1);
            catch
                vrGainCorr = csvread(vcFile_csv, 0, 0);
            end
        catch
        end
    end

    % build scale
    for iFile = 1:nFiles
        vrGainCorr1 = vrGainCorr(Smeta1.viSites + double(S_imec3.nSites_bank*S_imec3.viBank(iFile)));
        mrScale_ap(:,iFile) = 1.2 * 1e6 / 2^10 / S_imec3.vrGain_ap(iFile) .* vrGainCorr1;
        mrScale_lf(:,iFile) = 1.2 * 1e6 / 2^10 / S_imec3.vrGain_lf(iFile) .* vrGainCorr1;
    end
    S_imec3.mrScale_ap = mrScale_ap;
    S_imec3.mrScale_lf = mrScale_lf;
end
